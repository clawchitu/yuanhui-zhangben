import ShopCore
import SwiftUI

/// 21a →「账号与密码」（S23b）：账号名、改密码、让其他手机全部退出、注销账号。注销申请中时顶上一块「撤回注销」。
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
                OfflineNote(text: "要联网才能改密码、注销")
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
                deletionCard
                SettingsCard {
                    infoRow("账号", model.accountName ?? "这台手机是扫码登录的", id: "account.username")
                    RowDivider()
                    infoRow("店", model.session.storeName, id: "account.store")
                }
                passwordSection
                if model.capabilities.has(.manageDevices) { othersSection }
                if account.deletion == .none {
                    SettingsCard { SettingsLink(.deleteAccount, title: "注销账号") }
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .confirmSheet(item: $account.askRevokeOthers) { _ in
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

    // MARK: 注销申请中（7 天内用账号密码登录后撤回；过了 7 天显示「正在删除」，不给撤回，§14 S03-4）

    @ViewBuilder private var deletionCard: some View {
        switch account.deletion {
        case .none:
            if let msg = account.cancelMessage {
                Text(msg).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.cancelMessage")
            }
        case .pending(let until):
            VStack(alignment: .leading, spacing: 12) {
                Text("账号正在注销").font(TypeScale.title).accessibilityIdentifier("account.deletePending")
                Text("\(AccountModel.when(until)) 以后删除服务器上的账。现在撤回，账号照常用，这期间记在手机上的账会自动补传。")
                    .font(TypeScale.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.deletePending.text")
                PrimaryButton(account.cancelling ? "正在撤回…" : "撤回注销", mode: .neutral, style: .dark) {
                    Task { await account.cancelDeletion() }
                }
                .disabled(account.cancelling)
                .accessibilityIdentifier("account.cancelDeletion")
                if let msg = account.cancelMessage {
                    Text(msg).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Tokens.Palette.sell)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.cancelMessage")
                }
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
        case .deleting:
            Text("账号已经过了 7 天的撤回期，正在删除，撤回不了了。")
                .font(TypeScale.body.weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .accessibilityIdentifier("account.deleting")
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

/// 23 注销账号。「不注销了」是实心主按钮，「确认注销」是描边（review-1119-mockups 第 13 条：破坏性操作不做最显眼的那个）。
/// 要再输一次密码；页面上的期限和 §9.4 一致：7 天内可撤回，到期删除在线数据和商品图，备份在此后 35 天内清除
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var delete: DeleteAccountModel?
    @FocusState private var focused: Bool

    /// 两个按钮的样式（单元测试钉住：不注销了 = 实心，确认注销 = 描边）
    static let keepStyle: PrimaryButton.Style = .dark
    static let confirmStyle: PrimaryButton.Style = .ghost

    /// 要删什么（23 稿白卡里的两条）
    static let whatGoes = ["店里的商品、记的账、报表全部删除", "所有登录的手机都会退出，包括收银员的"]
    /// 期限（§9.4、§10 隐私政策同一口径）
    static let deadline = "提交后 7 天内可以撤回（用账号密码登录后撤回）。7 天后删除服务器上的账和商品图，备份在之后 35 天内清除，找不回来。注销期间不能记账。"

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.deleteAccount.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { if delete?.busy != true { dismiss() } })
            if let delete {
                content(delete)
            } else {
                OfflineNote(text: "要联网才能注销")
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear { if delete == nil { delete = makeModel() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.deleteAccount.pageId)
    }

    private func makeModel() -> DeleteAccountModel? {
        guard model.services != nil else { return nil }
        let db = model.db
        return DeleteAccountModel(submit: { [model] pw in await model.requestAccountDeletion(password: pw) }) { outcome in
            var info: [String: Any] = [:]
            if case .done(let until) = outcome { info["notice"] = Self.loginNotice(until: until) }
            NotificationCenter.default.post(name: AppRoot.signedOut, object: db, userInfo: info)
        }
    }

    /// 回到登录页后顶上那句话
    static func loginNotice(until: String) -> String {
        let when = APIClient.date(until).map(AccountModel.when)
        return "已经申请注销。" + (when.map { "\($0) 之前" } ?? "7 天内") + "用账号密码登录，可以撤回。"
    }

    @ViewBuilder private func content(_ d: DeleteAccountModel) -> some View {
        @Bindable var d = d
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("注销「\(model.accountName ?? model.session.storeName)」")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deleteAccount.title")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.whatGoes, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•")
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("deleteAccount.what")
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 24, weight: .semibold)).accessibilityHidden(true)
                    Text(Self.deadline).font(TypeScale.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.Palette.ink)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("deleteAccount.deadline")
                VStack(alignment: .leading, spacing: 8) {
                    Text("再输一次密码").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                    SecureField("", text: $d.password)
                        .font(.system(size: 24, weight: .semibold))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .focused($focused)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 64)
                        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(focused ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: focused ? 2.5 : 2))
                        .accessibilityLabel("再输一次密码")
                        .accessibilityIdentifier("deleteAccount.password")
                }
                if let msg = d.message {
                    Text(msg).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.sell)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("deleteAccount.message")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        // 两个按钮钉在底部（小屏、大字时也不被挤出屏幕）
        VStack(spacing: 10) {
            PrimaryButton("不注销了", mode: .neutral, style: Self.keepStyle) { dismiss() }
                .disabled(d.busy)
                .accessibilityValue("实心")
                .accessibilityIdentifier("deleteAccount.keep")
            PrimaryButton(d.busy ? "正在提交…" : "确认注销", mode: .neutral, style: Self.confirmStyle) {
                focused = false
                Task { await d.confirm() }
            }
            .disabled(!d.canSubmit)
            .accessibilityValue("描边")
            .accessibilityIdentifier("deleteAccount.confirm")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Tokens.Palette.paper)
    }
}
