import SwiftUI

/// 把扫码枪接到页面上：在页面背景里放一个隐形的按键接收视图，按键交给 `hub`。
/// 页面上的输入框要打字时把 `active` 设成假（例如手输条码面板打开时）。
struct ScannerInput: ViewModifier {
    let hub: ScanHub
    var active: Bool

    func body(content: Content) -> some View {
        content.background(
            HIDKeyCapture(isActive: active) { key, time in hub.key(key, at: time) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

extension View {
    /// 接扫码枪（见 `ScannerInput`）
    func scannerInput(_ hub: ScanHub, active: Bool = true) -> some View {
        modifier(ScannerInput(hub: hub, active: active))
    }
}

/// 回到前台时重新读相机权限（§14 S14-3 ⑩）。只在页面上没有取景框（被拒，出 27a）时由页面读；
/// 有取景框时 `CameraController` 回前台会读，这里不再读——两处只留一处（PR #17 Fable 第二轮）。
struct CameraPermissionRefresh: ViewModifier {
    let permission: CameraPermission
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active, permission.access == .denied { permission.refresh() }
        }
    }
}

extension View {
    func refreshesCameraPermission(_ permission: CameraPermission) -> some View {
        modifier(CameraPermissionRefresh(permission: permission))
    }
}

/// 取景框：相机允许时是相机画面 + 黄色对角框；还没问过时出「正在打开相机…」并弹系统询问；
/// 机器上没有相机（模拟器）时出「这台机器没有相机」。被拒时不该用它，用 `NoCameraBand` / `NoCameraCard`。
///
/// 相机的启停在这里统一决定（`CameraController`）：取景框看得见（`onAppear` / `onDisappear`，压到下一页也算看不见）、
/// App 在前台、相机允许、`paused` 为假（页面被面板盖住时设真），才开；回前台先重新读权限。
struct CameraViewfinder: View {
    let hub: ScanHub
    let permission: CameraPermission
    var includeQR = false
    /// 测试 / 截图时不开真相机（Debug 夹具强制了权限状态时）
    var hasCamera = CameraSession.hasCamera
    /// 页面让相机暂停（被面板盖住、弹窗中）
    var paused = false
    /// 扫码登录页（S21）用：相机认出的码原样交给页面，不经 `hub`。`ScanHub.isAcceptable` 只收数字和字母，
    /// 会把 `YHZB1:…` 里的 `:` 拒掉；登录码由页面交给 `PairingCode.parse` 判断
    var onRawCode: (@MainActor (String) -> Void)? = nil
    /// 黄角样式：扫码登录页用稿子上的两个角；卖出 / 进货页用四个加粗的角（扫码页布局方案）
    var corners: FinderCorners.Style = .standard

    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: CameraBox?
    @State private var visible = false

    /// 一个取景框一套相机（建在 `onAppear` 里，模拟器上没有会话）
    @MainActor final class CameraBox {
        let session: CameraSession?
        let controller: CameraController
        init(hasCamera: Bool, includeQR: Bool, permission: CameraPermission, hub: ScanHub,
             onRawCode: (@MainActor (String) -> Void)?) {
            session = hasCamera ? CameraSession(includeQR: includeQR) : nil
            controller = CameraController(runner: session, permission: permission)
            if let onRawCode {
                // 扫码登录页：一帧只取一个码（登录码是 QR，一次一个），不经扫码层
                controller.onFrame = { if let code = ($0.first { $0.kind == .qr } ?? $0.first) { onRawCode(code.value) } }
            } else {
                // 进货、卖出两页所有暂停→恢复路径（面板、手输页、登记页返回、切后台回来）走同一个防重放（PR #40 Codex 2 / Fable）
                controller.attach(to: hub)
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black
            switch permission.access {
            case .authorized where hasCamera:
                if let session = camera?.session { CameraPreview(camera: session) }
            case .authorized:
                note("这台机器没有相机")
            case .notDetermined:
                note("正在打开相机…")
            case .denied:
                note("没打开相机，扫不了码")
            }
            FinderCorners(style: corners)
                .stroke(Tokens.Palette.tag, style: StrokeStyle(lineWidth: corners.lineWidth, lineCap: .square))
                .padding(corners.inset)
                .allowsHitTesting(false)   // 点按对焦：点在框角上也交给相机画面
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task { await permission.requestIfNeeded() }
        .onAppear {
            if camera == nil {
                camera = CameraBox(hasCamera: hasCamera, includeQR: includeQR, permission: permission, hub: hub,
                                   onRawCode: onRawCode)
            }
            visible = true
            syncCamera()
        }
        .onDisappear {
            visible = false
            syncCamera()
        }
        .onChange(of: scenePhase) { syncCamera() }
        .onChange(of: permission.access) { syncCamera() }
        .onChange(of: paused) { syncCamera() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scanner.viewfinder")
    }

    private func syncCamera() {
        camera?.controller.update(visible: visible, sceneActive: scenePhase == .active, paused: paused)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(NoCameraBand.captionColor)
            .multilineTextAlignment(.center)
            .padding(8)
    }
}

/// 取景框的黄色直角。`.standard`：左上、右下两个（03 / 14 稿，扫码登录页）；`.bold`：四个角、线更粗、角更长（扫码页布局方案）
struct FinderCorners: Shape {
    enum Style: Equatable {
        case standard, bold
        var lineWidth: CGFloat { self == .bold ? 6 : 4 }
        var length: CGFloat { self == .bold ? 34 : 26 }
        var inset: CGFloat { self == .bold ? 8 : 6 }
    }

    var style: Style = .standard

    func path(in r: CGRect) -> Path {
        let l = style.length
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
            if style == .bold {
                p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
                p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
            }
        }
    }
}

/// 27a：卖出 / 进货 / 盘点页顶上相机条的「没打开相机」状态。
/// 「去打开」跳系统设置；「手输条码」和扫码枪照常能用（扫码枪由页面上的 `scannerInput` 接，不依赖相机）。
struct NoCameraBand: View {
    var onOpenSettings: @MainActor () -> Void = { CameraPermission.openSettings() }
    var onManual: @MainActor () -> Void

    static let background = Color(hex: 0x2B2622)
    static let captionColor = Color(hex: 0xD9D2C4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("没打开相机，扫不了码")
                .font(TypeScale.title.weight(.bold))
                .foregroundStyle(Tokens.Palette.card)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text("去打开")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("scanner.openSettings")
                Button(action: onManual) {
                    Label("手输条码", systemImage: "keyboard")
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Tokens.Palette.card)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.Palette.card, lineWidth: 2.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("scanner.manual")
            }
            Text("扫码枪照常能用")
                .font(TypeScale.secondary)
                .foregroundStyle(Self.captionColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scanner.noCamera")
    }
}

/// 27b：扫码登录页（S21）整块取景框位置上的「没打开相机」卡片：虚线框里一句话 + 说明 + 「去打开」。
struct NoCameraCard: View {
    var onOpenSettings: @MainActor () -> Void = { CameraPermission.openSettings() }

    static let dash = Color(hex: 0x6E6964)
    static let detail = Color(hex: 0xCFC9BF)

    var body: some View {
        VStack(spacing: 14) {
            Text("没打开相机，扫不了码")
                .font(TypeScale.title.weight(.bold))
                .foregroundStyle(Tokens.Palette.card)
            Text("在系统设置里给「元辉账本」打开相机")
                .font(TypeScale.body)
                .foregroundStyle(Self.detail)
            Button(action: onOpenSettings) {
                Text("去打开")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .frame(width: 220, height: 72)
                    .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: 20))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .padding(.top, 4)
            .accessibilityIdentifier("scanner.openSettings")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 22)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Self.dash, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7])))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scanner.noCameraCard")
    }
}
