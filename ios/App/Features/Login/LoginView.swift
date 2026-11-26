import ShopCore
import SwiftUI

/// 13 登录页 / 25c 锁定（S21）。页面上没有「注册」字样、没有店名（副标题「小店扫码记账」）；
/// 页脚只写「账号由店里开通」（稿子原文「不对外注册」与验收冲突，改掉，见 PR 已知偏差）。
struct LoginView: View {
    @Bindable var model: LoginModel
    @FocusState private var focus: Field?

    enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let notice = model.notice {
                    Text(notice)
                        .font(TypeScale.body.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                        .padding(.top, 26)
                        .accessibilityIdentifier("login.notice")
                }
                if let lock = model.lockText {
                    lockBanner(lock).padding(.top, 26)
                }
                fieldLabel("账号").padding(.top, model.locked ? 18 : 30)
                usernameField
                fieldLabel("密码").padding(.top, 18)
                passwordField
                if let message = model.message {
                    Text(message)
                        .font(TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.sell)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .accessibilityIdentifier("login.message")
                }
                loginButton.padding(.top, 14)
                orDivider.padding(.vertical, 18)
                scanButton
                Text("账号由店里开通")
                    .font(TypeScale.body)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .accessibilityIdentifier("login.footer")
                if model.services?.demoLoginEnabled == true {
                    Button {
                        Task { await model.demo() }
                    } label: {
                        Text("看看演示")
                            .font(TypeScale.body.weight(.semibold))
                            .underline()
                            .foregroundStyle(Tokens.Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle())
                    .disabled(model.busy)
                    .padding(.top, 6)
                    .accessibilityIdentifier("login.demo")
                }
                Link(destination: model.services?.privacyURL ?? URL(string: "https://yuanhuishop.cn/privacy")!) {
                    Text("隐私政策")
                        .font(TypeScale.body)
                        .underline()
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.top, 20)
                .accessibilityIdentifier("login.privacy")
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.login")
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppMark().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppRoot.title)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Tokens.Palette.ink)
                Text("小店扫码记账")
                    .font(.system(size: 22))
                    .foregroundStyle(Tokens.Palette.ink2)
                    .accessibilityIdentifier("login.subtitle")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private func lockBanner(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 22, weight: .semibold))
            Text(text)
                .font(TypeScale.body.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("login.locked")
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2).padding(.bottom, 8)
    }

    private func box<C: View>(focused: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 18)
            .frame(minHeight: 64)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(focused ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: focused ? 2.5 : 2))
    }

    private var usernameField: some View {
        box(focused: focus == .username) {
            TextField("", text: $model.username)
                .font(.system(size: 24, weight: .semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .submitLabel(.next)
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
                .accessibilityIdentifier("login.username")
            if model.remembered {
                Text("记住了")
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .accessibilityIdentifier("login.remembered")
            }
        }
    }

    private var passwordField: some View {
        box(focused: focus == .password) {
            Group {
                if model.showPassword {
                    TextField("", text: $model.password)
                        .accessibilityIdentifier("login.passwordPlain")
                } else {
                    SecureField("", text: $model.password)
                        .accessibilityIdentifier("login.password")
                }
            }
            .font(.system(size: 24, weight: .semibold))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .submitLabel(.go)
            .focused($focus, equals: .password)
            .onSubmit { Task { await model.login() } }
            Button {
                model.showPassword.toggle()
            } label: {
                Label(model.showPassword ? "隐藏" : "显示", systemImage: model.showPassword ? "eye.slash" : "eye")
                    .font(TypeScale.secondary.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.ink2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("login.showPassword")
        }
    }

    private var loginButton: some View {
        PrimaryButton(model.locked ? "登录（锁定中）" : (model.busy ? "正在登录…" : "登录"), style: .dark) {
            focus = nil
            Task { await model.login() }
        }
        .disabled(!model.canSubmit)
        .accessibilityIdentifier("login.submit")
    }

    private var orDivider: some View {
        HStack(spacing: 18) {
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
            Text("或者").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2).fixedSize()
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
        }
    }

    private var scanButton: some View {
        Button {
            focus = nil
            model.scanOpen = true
        } label: {
            Label("扫家里人手机上的码", systemImage: "qrcode")
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.primaryButton)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("login.scan")
    }
}

/// App 图标的样子：红底圆角方块里一个白色「账」
struct AppMark: View {
    var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: g.size.width * 0.22)
                .fill(Tokens.Palette.sell)
                .overlay(Text("账").font(.system(size: g.size.width * 0.58, weight: .heavy)).foregroundStyle(.white))
        }
        .accessibilityHidden(true)
    }
}

/// 整屏「请更新」：`/v1/config` 的 `min_build` 高于本包时盖住一切（S21）
struct UpdateRequiredView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppMark().frame(width: 72, height: 72)
            Text("请更新")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Tokens.Palette.ink)
            Text("这一版太旧了，请到 App Store 把「元辉账本」更新到最新版再用。")
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.updateRequired")
    }
}
