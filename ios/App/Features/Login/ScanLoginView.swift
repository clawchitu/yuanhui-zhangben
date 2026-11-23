import ShopCore
import SwiftUI

/// 14 扫码登录 / 27b 没打开相机（S21）。黑底；整页用深色外观，状态栏是浅色字（§14 S14-3 ⑬）。
/// 相机认出的码不经 `ScanHub`（它只收数字和字母，会拒掉 `YHZB1:` 里的 `:`），原样交给 `LoginModel.scanned`，
/// 由 `PairingCode.parse` 判断。
struct ScanLoginView: View {
    @Bindable var model: LoginModel
    @State private var permission: CameraPermission
    @State private var hub = ScanHub()
    private let hasCamera: Bool
    #if DEBUG
    /// `-uiLoginCode YHZB1:…`：开页 1 秒后当作相机认出这个码（测试、截图用）
    private let fakeCode: String?
    #endif

    init(model: LoginModel, args: [String] = ProcessInfo.processInfo.arguments) {
        self.model = model
        #if DEBUG
        let forced = CameraPermission.forcedAccess(from: args)
        fakeCode = UIFixture.value(for: "-uiLoginCode", in: args)
        #else
        let forced: CameraAccess? = nil
        #endif
        _permission = State(initialValue: CameraPermission(forced: forced))
        hasCamera = forced == nil && CameraSession.hasCamera
    }

    static let caption = Color(hex: 0xCFC9BF)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    if permission.access == .denied {
                        NoCameraCard()
                            .padding(.top, 36)
                        Text("也可以先用账号密码登录")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Tokens.Palette.card)
                            .padding(.top, 34)
                    } else {
                        CameraViewfinder(hub: hub, permission: permission, includeQR: true, hasCamera: hasCamera,
                                         paused: model.busy,
                                         onRawCode: { raw in Task { await model.scanned(raw) } })
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.horizontal, 30)
                            .padding(.top, 28)
                        Text("让家里人打开\n「更多 → 给家里人 / 收银员开通」\n把那个二维码对准这里")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Tokens.Palette.card)
                            .padding(.top, 28)
                    }
                    Text("收银员也扫这个码，让家里人选「收银员」那页")
                        .font(TypeScale.body)
                        .foregroundStyle(Self.caption)
                        .padding(.top, 12)
                    if model.busy {
                        ProgressView().tint(Tokens.Palette.card).padding(.top, 16)
                    }
                    if let msg = model.scanMessage {
                        Text(msg)
                            .font(TypeScale.body.weight(.bold))
                            .foregroundStyle(Tokens.Palette.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                            .padding(.top, 16)
                            .accessibilityIdentifier("scanLogin.message")
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            }
            Button { model.scanOpen = false } label: {
                Text("用账号密码登录")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Tokens.Palette.card)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Size.primaryButton)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button)
                        .strokeBorder(Tokens.Palette.card, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .accessibilityIdentifier("scanLogin.password")
        }
        .background(Tokens.Palette.ink.ignoresSafeArea())
        // 黑底页：状态栏用浅色字（S14-3 ⑬），相机被拒出 27b 卡片时也一样
        .preferredColorScheme(.dark)
        .refreshesCameraPermission(permission)
        #if DEBUG
        .task {
            guard let fakeCode else { return }
            try? await Task.sleep(for: .seconds(1))
            await model.scanned(fakeCode)
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.scanLogin")
    }

    private var header: some View {
        ZStack {
            Text("扫码登录").font(.system(size: 24, weight: .bold))
            HStack {
                Button { model.scanOpen = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: Tokens.Size.minHitTarget, height: Tokens.Size.minHitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("返回")
                .accessibilityIdentifier("scanLogin.back")
                Spacer()
            }
        }
        .foregroundStyle(Tokens.Palette.card)
        .padding(.horizontal, 8)
        .frame(height: 60)
    }
}

/// 没有会话时的登录流程：13 登录页，点「扫家里人手机上的码」盖上 14 扫码登录页（整屏）
struct LoginFlow: View {
    @State private var model: LoginModel

    init(model: LoginModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        LoginView(model: model)
            .fullScreenCover(isPresented: $model.scanOpen) {
                ScanLoginView(model: model)
            }
    }
}
