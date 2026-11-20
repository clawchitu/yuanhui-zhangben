import GameController
import SwiftUI
import UIKit

/// 接住扫码枪按键的隐形视图：做第一响应者，在 `pressesBegan` 里把每个按键交给 `onKey`（通常是 `ScanHub.key`）。
/// 它不是文本输入控件，所以成为第一响应者不会弹出软键盘。
///
/// 页面上有输入框正在输入时（例如手输条码），按键归那个输入框；把 `isActive` 设成假，输入结束后再设回真，
/// 这里会重新抢回第一响应者。App 回到前台、软键盘收起时也会抢回。
final class HIDKeyCaptureView: UIView {
    var onKey: ((HIDScanParser.Key, TimeInterval) -> Void)?
    var isActive = true {
        didSet { if isActive { reclaim() } else if isFirstResponder { resignFirstResponder() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reclaim), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(reclaim), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("不用 storyboard") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reclaim()
    }

    /// 抢回第一响应者（下一轮主循环再做，避开 SwiftUI 正在布局的时候）
    @objc func reclaim() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    static func key(for uiKey: UIKey) -> HIDScanParser.Key {
        if uiKey.keyCode == .keyboardReturnOrEnter || uiKey.keyCode == .keypadEnter { return .enter }
        // 扫码枪发大写字母时带 Shift，其余修饰键说明是人在按快捷键
        let modifiers = uiKey.modifierFlags.subtracting([.shift, .alphaShift, .numericPad])
        guard modifiers.isEmpty, uiKey.characters.count == 1, let c = uiKey.characters.first else { return .other }
        return .character(c)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let keyed = presses.filter { $0.key != nil }.sorted { $0.timestamp < $1.timestamp }
        for press in keyed {
            onKey?(Self.key(for: press.key!), press.timestamp)
        }
        let rest = presses.subtracting(keyed)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    // 按下时接住的键，抬起等事件也接住，不往上传
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { $0.key == nil }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { $0.key == nil }
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

/// SwiftUI 里放一个 `HIDKeyCaptureView`（零尺寸，放在页面背景里）。
struct HIDKeyCapture: UIViewRepresentable {
    var isActive: Bool
    var onKey: (HIDScanParser.Key, TimeInterval) -> Void

    func makeUIView(context: Context) -> HIDKeyCaptureView {
        let v = HIDKeyCaptureView(frame: .zero)
        v.onKey = onKey
        v.isActive = isActive
        return v
    }

    func updateUIView(_ v: HIDKeyCaptureView, context: Context) {
        v.onKey = onKey
        if v.isActive != isActive { v.isActive = isActive }
    }
}

/// 扫码枪连没连上：扫码枪在系统看来就是一个硬件键盘（GameController 的 `GCKeyboard`）。
/// 设置页「扫码枪 已连上 / 没连」和首页的扫码枪状态由 S16 接到这里（§14 S15-1）。
@MainActor @Observable
final class ScannerGunMonitor {
    private(set) var connected: Bool
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        connected = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.connected = GCKeyboard.coalesced != nil }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
