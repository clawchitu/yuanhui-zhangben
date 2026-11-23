import Foundation

/// 码从哪儿来
enum ScanSource: String, Equatable, Sendable, CaseIterable {
    case camera
    /// 蓝牙扫码枪（HID 键盘）
    case gun
    /// 手输条码（S17 的面板）
    case manual

    var label: String {
        switch self {
        case .camera: "相机"
        case .gun: "扫码枪"
        case .manual: "手输"
        }
    }
}

/// 一次扫码
struct Scan: Equatable, Sendable {
    let code: String
    let source: ScanSource
}

/// 相机一帧里认出的一个码（带码制：一次只认一件要按码制过滤）
struct CameraCode: Equatable, Sendable {
    enum Kind: Sendable { case ean13, ean8, upce, itf14, code128, qr, other }
    let value: String
    let kind: Kind
    init(_ value: String, kind: Kind) { self.value = value; self.kind = kind }
}

/// 页面处理完一次扫码后告诉扫码层结果，扫码层据此出声、震动
enum ScanOutcome: Equatable, Sendable {
    /// 登记过的码（高而短的「嘀」+ 成功触感）
    case known
    /// 没登记过的码（另一种低音「嘟—嘟」+ 警告触感）
    case unknown
    /// 页面这会儿不收码（例如正在弹窗）：不出声
    case ignored
}

/// 提示音 + 触感。正式实现是 `ScanFeedback`，测试换成记录器。
@MainActor
protocol ScanFeedbackPlaying: AnyObject {
    func play(_ outcome: ScanOutcome)
}

/// 扫码层的汇合点：相机、扫码枪、手输条码（以及 Debug 的 `FakeScanner`）都把码交到这里，
/// 这里做相机去重、扫码枪按键解析，然后交给页面的 `handler`，再按页面给的结果出声和震动。
///
/// 用法（S16 卖出页）：页面持有一个 `ScanHub`，设 `handler` 查本地库、往购物篮里加；
/// 页面上放 `ScannerInput(hub:)`（接扫码枪）和 `CameraArea(hub:)`（相机 / 权限三态）。
@MainActor
final class ScanHub {
    /// 页面处理扫码。返回 `.known` / `.unknown` 决定提示音；没设时一律当 `.ignored`
    var handler: ((Scan) -> ScanOutcome)?

    private let feedback: ScanFeedbackPlaying?
    private let clock: () -> TimeInterval
    /// 相机「离开多久算新的一次」：1.5 秒（有效时钟）
    let cameraWindow: TimeInterval
    private var parser: HIDScanParser

    init(feedback: ScanFeedbackPlaying? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         cameraWindow: TimeInterval = CameraDeduper.defaultWindow,
         gunConfig: HIDScanParser.Config = .init()) {
        self.feedback = feedback
        self.clock = clock
        self.cameraWindow = cameraWindow
        self.parser = HIDScanParser(config: gunConfig)
    }

    /// 手输条码（或测试里的单码相机帧）交来一个码。空码、含数字和字母以外字符的码（首尾的空格、Tab、换行也算，
    /// 不先裁掉）返回 nil（不出声、不交给页面），否则返回页面的处理结果。
    /// `.camera` 等同于只有这一个码的一帧（`receiveFrame([code])`），按相机规则判定。
    @discardableResult
    func receive(_ code: String, from source: ScanSource) -> ScanOutcome? {
        guard source == .camera else {
            guard Self.isAcceptable(code) else { return nil }
            return deliver(Scan(code: code, source: source))
        }
        return receiveFrame([code])
    }

    // MARK: - 相机：有效时钟 + 资格（PR #40 第三轮重写 + Fable 补洞，进货、卖出共用）
    //
    // 1. 有效时钟：只在相机开着时走；停相机（抹零、手输、登记页、切后台、收起相机区、离开页面）期间不走；
    //    开相机后冻结到收到第一批识别回调才走（首回调晚到的那段不算「离开」）。
    // 2. 每帧识别区内的所有商品码（选没选中、页面收不收都算）都按有效时钟记「最后看见」。
    // 3. 一个码出现时，距它上次被看见满离开阈值（有效时钟）或从没见过，给它「可记一次」的资格；一直在画面里不会再得资格。
    //    离开阈值：从没记过的码 1.5 秒；本页已记过的码 2.5 秒（防漏帧：识别断档不当成拿开）。
    // 4. 一次只认一件（负责人 11/23 决定）：一帧滤完只剩一个码、它有资格、页面收了，才算记一笔并用掉资格。
    //    滤完 ≥ 2 个不同的码：什么都不交、不用掉资格，提示「一次扫一件」。
    //    过滤：只收数字字母；EAN-13 / EAN-8 / UPC-E 校验位要对；ITF-14（校验位要对）和 Code128 只在同帧没有 EAN / UPC 时才算；
    //    同一码值多个框算一个。
    // 5. 页面从「不收」转回「收」（相机重开、进货商品卡关掉，`inputResumed`）：清空所有码的资格——还在画面里的要拿开再扫。

    /// 码 → 最后一次被看见的有效时钟
    private var lastSeen: [String: TimeInterval] = [:]
    /// 有「可记一次」资格的码
    private var eligible: Set<String> = []
    /// 本页相机记过的码（离开阈值加长）
    private var recorded: Set<String> = []
    /// 已记过的码的离开阈值
    static let recordedWindow: TimeInterval = 2.5
    /// 有效时钟：已累计的部分，和这一段开始走时的真实时钟（nil：停着，或开了还没收到识别回调）
    private var effectiveBase: TimeInterval = 0
    private var runningSince: TimeInterval?
    private var cameraOn = true
    /// 上一次提示「一次扫一件」的有效时钟
    private var lastSeveralNotice: TimeInterval?
    /// 一帧里有好几个码：页面出「一次扫一件」提示（最多 2 秒一次）
    var onSeveralCodes: (() -> Void)?

    private var effectiveNow: TimeInterval {
        guard let s = runningSince else { return effectiveBase }
        return effectiveBase + max(0, clock() - s)
    }

    /// 相机要停了：有效时钟停走
    func cameraPaused() {
        effectiveBase = effectiveNow
        runningSince = nil
        cameraOn = false
    }

    /// 相机（重新）开了：有效时钟冻结到第一个识别回调；页面转回收码，清空资格
    func cameraResumed() {
        effectiveBase = effectiveNow
        runningSince = nil
        cameraOn = true
        inputResumed()
    }

    /// 页面从「不收」转回「收」（进货商品卡关掉等）：所有码的资格清空，还在画面里的要拿开再扫
    func inputResumed() {
        eligible = []
    }

    /// 一帧里算数的商品码（过滤规则见上面第 4 条）
    static func productCodes(in frame: [CameraCode]) -> [String] {
        let ok = frame.filter { isAcceptable($0.value) }
        let primary = ok.filter {
            switch $0.kind {
            case .ean13: $0.value.count == 13 && GTIN.checkDigitOK($0.value)
            case .ean8: $0.value.count == 8 && GTIN.checkDigitOK($0.value)
            case .upce: GTIN.upceOK($0.value)
            case .other: true   // 码制不明（Debug 夹具 / 测试的单码入口）
            case .itf14, .code128, .qr: false
            }
        }
        let picked = primary.isEmpty ? ok.filter {
            switch $0.kind {
            case .itf14: $0.value.count == 14 && GTIN.checkDigitOK($0.value)
            case .code128: true
            default: false
            }
        } : primary
        var seen = Set<String>()
        return picked.map(\.value).filter { seen.insert($0).inserted }
    }

    /// 测试 / 夹具用：码制不明的一帧
    @discardableResult
    func receiveFrame(_ values: [String]) -> ScanOutcome? {
        receiveFrame(values.map { CameraCode($0, kind: .other) })
    }

    /// 相机交来一帧（识别区内的所有码）。返回页面的处理结果；没交给页面时返回 nil
    @discardableResult
    func receiveFrame(_ frame: [CameraCode]) -> ScanOutcome? {
        if runningSince == nil, cameraOn { runningSince = clock() }
        let now = effectiveNow
        let codes = Self.productCodes(in: frame)
        if lastSeen.count > 64 { lastSeen = lastSeen.filter { now >= $0.value && now - $0.value < Self.recordedWindow } }
        for c in codes {
            let window = recorded.contains(c) ? Self.recordedWindow : cameraWindow
            if let seen = lastSeen[c], now >= seen, now - seen < window {} else { eligible.insert(c) }
            lastSeen[c] = now
        }
        guard codes.count == 1, let code = codes.first else {
            if codes.count > 1, lastSeveralNotice.map({ now - $0 >= 2 || now < $0 }) ?? true {
                lastSeveralNotice = now
                onSeveralCodes?()
            }
            return nil
        }
        guard eligible.contains(code) else { return nil }
        let outcome = deliver(Scan(code: code, source: .camera))
        if let outcome, outcome != .ignored {
            eligible.remove(code)
            if outcome == .known { recorded.insert(code) }
        }
        return outcome
    }

    /// 扫码枪的一个按键（`HIDKeyCaptureView` 交来；时间用 UIPress.timestamp，与 `clock` 同一个时基：开机以来的秒数）
    @discardableResult
    func key(_ key: HIDScanParser.Key, at time: TimeInterval) -> ScanOutcome? {
        guard let code = parser.feed(key, at: time) else { return nil }
        return deliver(Scan(code: code, source: .gun))
    }

    /// 三个入口（相机、扫码枪、手输）同一个字符规则（§14 S14-5）：只收数字和 ASCII 大小写字母，
    /// 含其他字符整串不收、不截断；大小写原样保留。扫码枪的解析器已经按同一个 `isCodeCharacter` 作废，这里再挡一层
    static func isAcceptable(_ code: String) -> Bool {
        !code.isEmpty && code.allSatisfy(HIDScanParser.isCodeCharacter)
    }

    private func deliver(_ scan: Scan) -> ScanOutcome? {
        guard Self.isAcceptable(scan.code) else { return nil }
        let outcome = handler?(scan) ?? .ignored
        if outcome != .ignored { feedback?.play(outcome) }
        return outcome
    }
}

/// 商品条码校验位（GS1：从右往左数，数据位权重 3、1 交替）
enum GTIN {
    static func checkDigitOK(_ code: String) -> Bool {
        let d = code.compactMap(\.wholeNumberValue)
        guard d.count == code.count, d.count >= 2 else { return false }
        return check(Array(d.dropLast())) == d.last
    }

    static func check(_ body: [Int]) -> Int {
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10
    }

    /// UPC-E（8 位：数制 + 6 位 + 校验位）：展开成 UPC-A 再算校验位
    static func upceOK(_ code: String) -> Bool {
        let d = code.compactMap(\.wholeNumberValue)
        guard d.count == 8, d.count == code.count, d[0] == 0 || d[0] == 1 else { return false }
        let (s, x) = (d[0], Array(d[1...6]))
        let a: [Int]
        switch x[5] {
        case 0, 1, 2: a = [s, x[0], x[1], x[5], 0, 0, 0, 0, x[2], x[3], x[4]]
        case 3: a = [s, x[0], x[1], x[2], 0, 0, 0, 0, 0, x[3], x[4]]
        case 4: a = [s, x[0], x[1], x[2], x[3], 0, 0, 0, 0, 0, x[4]]
        default: a = [s, x[0], x[1], x[2], x[3], x[4], 0, 0, 0, 0, x[5]]
        }
        return check(a) == d[7]
    }
}
