import ShopCore
import SwiftUI

/// 21a →「账号与密码」（S23b-1）：账号名、改密码、让其他手机全部退出。注销入口在 S23b-2 加。
/// 只有家用、审核有这一页（能力 `.account`，从 permissions.json 来）；收银员硬塞路由进来只看到「用不了」
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var account: AccountModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.account.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let account {
                AccountContent(account: account)
            } else {
                OfflineNote(text: "要联网才能改密码")
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if account == nil { account = model.makeAccountModel() }
            Task { await account?.refresh() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.account.pageId)
    }
}

private struct AccountContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var account: AccountModel
    @FocusState private var focus: Field?
    enum Field { case old, new, again }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard {
                    infoRow("账号", model.accountName ?? "联网后显示", id: "account.username")
                    RowDivider()
                    infoRow("店", model.session.storeName, id: "account.store")
                }
                passwordSection
                if model.capabilities.has(.manageDevices) { othersSection }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .confirmSheet(item: $account.askRevokeOthers, page: .account) { _ in
            ConfirmPanel(title: "让其他手机全部退出？",
                         message: "除了这台，所有登录的手机（包括收银员的）都要重新登录或扫码才能用。它们还没传上去的账会先传完。",
                         confirmTitle: "全部退出", cancelTitle: "不了", mode: .neutral,
                         confirmStyle: .dark, confirmImage: nil,
                         confirmId: "account.revokeOthers.confirm", cancelId: "account.revokeOthers.cancel",
                         busy: account.revokingOthers,
                         onConfirm: { Task { await account.revokeOthersConfirmed() } },
                         onCancel: { account.askRevokeOthers = nil })
            if let err = account.revokeError {
                Text(err).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.revokeOthers.error")
            }
        }
    }

    private func infoRow(_ title: String, _ value: String, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).font(TypeScale.body).fixedSize()
                Spacer(minLength: 0)
                Text(value).font(TypeScale.body.weight(.semibold)).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                Text(value).font(TypeScale.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: Tokens.Size.minHitTarget)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: 改密码

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("改密码").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink).padding(.top, 8)
            PasswordBox(label: "原来的密码", text: $account.oldPassword, id: "account.old", focus: $focus, field: .old,
                        contentType: .password, next: { focus = .new })
            PasswordBox(label: "新密码（至少 \(PasswordRule.minLength) 位）", text: $account.newPassword, id: "account.new",
                        focus: $focus, field: .new, next: { focus = .again })
            PasswordBox(label: "新密码再输一次", text: $account.newAgain, id: "account.again", focus: $focus, field: .again,
                        next: { focus = nil; Task { await account.changePassword() } })
            if let msg = account.passwordMessage {
                Text(msg)
                    .font(TypeScale.body.weight(.semibold))
                    .foregroundStyle(account.passwordChanged ? Tokens.Palette.ink : Tokens.Palette.sell)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.passwordMessage")
            }
            PrimaryButton(account.changing ? "正在改…" : "改密码", mode: .neutral, style: .dark) {
                focus = nil
                Task { await account.changePassword() }
            }
            .disabled(!account.canChange)
            .accessibilityIdentifier("account.changePassword")
            Text("改了以后，别的手机不用重新登录。")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 让其他手机全部退出（先弹 26 确认面板）

    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("其他手机").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink).padding(.top, 8)
            PrimaryButton("让其他手机全部退出", mode: .neutral, style: .ghost, size: .medium) {
                focus = nil
                account.askRevokeOthers = .init()
            }
            .accessibilityIdentifier("account.revokeOthers")
            if let done = account.revokeDone {
                Text(done).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.revokeOthers.done")
            }
            Text("手机丢了、或者怕密码被别人知道了，就点这里。")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 一个密码框：上面一行说明，框里是圆点
private struct PasswordBox<F: Hashable>: View {
    let label: String
    @Binding var text: String
    let id: String
    var focus: FocusState<F?>.Binding
    let field: F
    /// 原密码填 `.password`（能用钥匙串自动填）；新密码不填，免得系统弹「强密码」
    var contentType: UITextContentType? = nil
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("", text: $text)
                .font(.system(size: 24, weight: .semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(contentType)
                .submitLabel(.next)
                .focused(focus, equals: field)
                .onSubmit(next)
                .padding(.horizontal, 18)
                .frame(minHeight: 64)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(focus.wrappedValue == field ? Tokens.Palette.ink : Tokens.Palette.line,
                                  lineWidth: focus.wrappedValue == field ? 2.5 : 2))
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }
}
