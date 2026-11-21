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

    /// 相机或手输条码交来一个码。空码、含数字和字母以外字符的码、被相机去重挡掉的码返回 nil（不出声、不交给页面），
    /// 否则返回页面的处理结果。
    @discardableResult
    func receive(_ code: String, from source: ScanSource) -> ScanOutcome? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAcceptable(code) else { return nil }
        if source == .camera, !deduper.accept(code, at: clock()) { return nil }
        return deliver(Scan(code: code, source: source))
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
