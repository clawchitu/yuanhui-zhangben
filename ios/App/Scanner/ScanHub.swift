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
        if heldOver(code, at: now) { return nil }
        if !deduper.accept(code, at: now) { return nil }
        let outcome = deliver(Scan(code: code, source: source))
        if outcome == .ignored, code != lastCameraCode {
            // 页面没收（进货页商品卡在 / 页面被盖住）：这个码没处理过，不占去重窗口，
            // 否则它一直在镜头里就一直刷新计时，恢复后也扫不进去（PR #40 Codex 必须修 1）。
            // 已经处理过的那个码照旧留着计时：还在镜头里就不重复算
            deduper.forget(code)
        } else if let outcome, outcome != .ignored {
            lastCameraCode = code
        }
        return outcome
    }

    /// 相机上一次处理过的码（页面收了的）
    private var lastCameraCode: String?
    /// 相机停过再开（进货页填数时相机区收起）：上一次处理过的码先挡着，直到它离开镜头满一个去重窗口
    private var holdOver: (code: String, since: TimeInterval, lastSeen: TimeInterval?)?
    /// 相机开起来之前的宽限（会话重启要一会儿）：过了这么久都没再看见它，就不挡了
    static let resumeGrace: TimeInterval = 1.0

    /// 相机停过、要重新开：不重放上一次处理过的码（PR #40 Codex 必须修 2）。停的这段时间去重计时过期了，
    /// 那件货还在镜头里的话，一开相机就会被当成新扫的一次，把刚确认完的商品又弹回来、挡住下一件
    func cameraResumed() {
        guard let code = lastCameraCode else { return }
        holdOver = (code, clock(), nil)
    }

    private func heldOver(_ code: String, at now: TimeInterval) -> Bool {
        guard let h = holdOver else { return false }
        let window = deduper.window
        // 离开镜头满一个窗口、或开了相机后一直没再看见：不再挡
        if let seen = h.lastSeen, now - seen >= window { holdOver = nil; return false }
        if h.lastSeen == nil, now - h.since >= window + Self.resumeGrace { holdOver = nil; return false }
        guard code == h.code else { return false }
        holdOver?.lastSeen = now
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
