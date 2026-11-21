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
        key(keyCode: uiKey.keyCode, characters: uiKey.characters, modifierFlags: uiKey.modifierFlags)
    }

    /// 单独按下就只是修饰键的键码：扫码枪打大写字母前会单独发一个 Shift 按下，不能因此清空缓冲
    static let modifierKeyCodes: Set<UIKeyboardHIDUsage> = [
        .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
        .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock,
    ]
    /// 带了就说明是人在按快捷键（Shift / Caps Lock / 小键盘标志是扫码枪正常会带的）
    static let shortcutModifiers: UIKeyModifierFlags = [.control, .command, .alternate]

    /// `UIKey` 的三个字段 → 解析器的按键（纯函数，单元测试直接喂）。
    /// 顺序：纯修饰键忽略 → **先查修饰键**（带 Control / Command / Option 的任何键、包括回车，都是非法键，让当前整串作废）
    /// → 再认普通回车和小键盘回车 → 单个字符交给解析器判合不合法。
    static func key(keyCode: UIKeyboardHIDUsage, characters: String, modifierFlags: UIKeyModifierFlags) -> HIDScanParser.Key {
        if modifierKeyCodes.contains(keyCode) { return .ignored }
        if !modifierFlags.isDisjoint(with: shortcutModifiers) { return .other }
        if keyCode == .keyboardReturnOrEnter || keyCode == .keypadEnter || keyCode == .keyboardReturn { return .enter }
        guard characters.count == 1, let c = characters.first else { return .other }
        return .character(c)
    }

    /// 这个键归不归扫码层（吞掉、不往上传）：条码字符和回车。其余的（Esc、Command 组合、方向键、修饰键）
    /// 照样交给解析器判，但也往上传给系统和外层
    static func consumes(_ key: HIDScanParser.Key) -> Bool {
        switch key {
        case .character(let c): HIDScanParser.isCodeCharacter(c)
        case .enter: true
        case .other, .ignored: false
        }
    }

    /// 按下时吞掉的那些按键，抬起 / 取消时同样吞掉（不按抬起时的修饰键重新判，免得上下不配对）
    private var consumed: Set<ObjectIdentifier> = []

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let uiKey = press.key else { rest.insert(press); continue }
            let key = Self.key(for: uiKey)
            onKey?(key, press.timestamp)
            if Self.consumes(key) { consumed.insert(ObjectIdentifier(press)) } else { rest.insert(press) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = passThrough(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = passThrough(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    private func passThrough(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { consumed.remove(ObjectIdentifier($0)) == nil }
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

    /// `probe`：现在连没连（测试注入）；连接 / 断开的通知来了再读一次
    init(probe: @escaping @MainActor () -> Bool = { GCKeyboard.coalesced != nil }) {
        connected = probe()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.connected = probe() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
