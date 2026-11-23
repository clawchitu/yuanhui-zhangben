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
    private var deduper: CameraDeduper
    private var parser: HIDScanParser

    init(feedback: ScanFeedbackPlaying? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         cameraWindow: TimeInterval = CameraDeduper.defaultWindow,
         gunConfig: HIDScanParser.Config = .init()) {
        self.feedback = feedback
        self.clock = clock
        self.deduper = CameraDeduper(window: cameraWindow)
        self.parser = HIDScanParser(config: gunConfig)
    }

    /// 相机或手输条码交来一个码。空码、含数字和字母以外字符的码（首尾的空格、Tab、换行也算，不先裁掉）、
    /// 被相机去重挡掉的码返回 nil（不出声、不交给页面），否则返回页面的处理结果。
    @discardableResult
    func receive(_ code: String, from source: ScanSource) -> ScanOutcome? {
        guard Self.isAcceptable(code) else { return nil }
        guard source == .camera else { return deliver(Scan(code: code, source: source)) }
        let now = clock()
        if processedSeen[code] != nil { processedSeen[code] = now }
        if heldOver(code, at: now) { return nil }
        if !deduper.accept(code, at: now) { return nil }
        let outcome = deliver(Scan(code: code, source: source))
        if outcome == .ignored, processedSeen[code] == nil {
            // 页面没收（进货页商品卡在 / 页面被盖住）：这个码没处理过，不占去重窗口，
            // 否则它一直在镜头里就一直刷新计时，恢复后也扫不进去（PR #40 Codex 必须修 1）。
            // 已经处理过的码照旧留着计时：还在镜头里就不重复算
            deduper.forget(code)
        } else if let outcome, outcome != .ignored {
            processedSeen[code] = now
        }
        return outcome
    }

    /// 相机处理过（页面收了）的码 → 相机最后一次看见它的时间（之后每次看见都刷新，去重挡掉、防重放挡掉的也算）
    private var processedSeen: [String: TimeInterval] = [:]
    /// 相机停过再开的防重放（PR #40 Codex 复审、Fable 必须修）：停相机前 1.5 秒内相机看见过的、处理过的码，每个码各自挡着。
    /// 码 → 恢复后最后一次看见的时间（nil：恢复后还没看见）。不设总时长（相机首个回调可能晚到），
    /// 也不因为看见别的码就解除；每个码只在离开镜头满一个去重窗口后解除：
    /// 恢复后看见过的按最后看见的时间算，没看见过的按恢复后第一个识别结果的时间算
    private var held: [String: TimeInterval?] = [:]
    /// 恢复后第一个识别结果的时间（nil：恢复后还没收到识别结果）
    private var firstFrameAt: TimeInterval?

    /// 相机要停了（页面被盖住、相机区收起、退到后台、离开页面）：记下这会儿还在镜头里的处理过的码
    func cameraPaused() {
        let now = clock()
        let window = deduper.window
        processedSeen = processedSeen.filter { _, seen in now >= seen && now - seen < window }
        // 上一次恢复后还挡着、没确认离开的码接着挡（恢复后没等到识别结果又停了）
        for code in Set(held.keys).union(processedSeen.keys) { held[code] = .some(nil) }
        firstFrameAt = nil
    }

    /// 相机停过、要重新开：停之前在镜头里的那几件不重放。停的这段时间去重计时过期了，
    /// 那几件还在镜头里的话，一开相机就会被当成新扫的，卖出页多记一件、进货页把刚确认完的商品又弹回来
    func cameraResumed() {
        for code in held.keys { held[code] = .some(nil) }
        firstFrameAt = nil
    }

    private func heldOver(_ code: String, at now: TimeInterval) -> Bool {
        guard !held.isEmpty else { return false }
        if firstFrameAt == nil { firstFrameAt = now }
        let window = deduper.window
        // 离开镜头满一个窗口的码解除（这一个码自己若到期，也按新的一次处理）
        held = held.filter { _, seen in
            guard let since = seen ?? firstFrameAt else { return true }
            return !(now >= since && now - since >= window)
        }
        guard held[code] != nil else { return false }
        held[code] = .some(now)
        return true
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
