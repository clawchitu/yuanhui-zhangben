import Observation
import ShopCore
import SwiftUI

/// 25b / 25f 的数据：被踢的原因和恢复队列还剩几笔（每次补传完刷新）
@MainActor @Observable
final class KickedModel {
    let db: LocalDB
    let cashier: Bool
    private(set) var pending: Int
    let onContinue: () -> Void

    init(db: LocalDB, cashier: Bool, onContinue: @escaping () -> Void) {
        self.db = db
        self.cashier = cashier
        self.onContinue = onContinue
        pending = (try? db.recoveryPendingCount()) ?? 0
    }

    func refresh() { pending = (try? db.recoveryPendingCount()) ?? 0 }

    /// 25b「重新登录」/ 25f「扫家里人给的码」：不再显示这页，进登录（收银员直接开扫码）
    func next() {
        try? db.clearSignOutReason()
        onContinue()
    }

    /// 黄卡上的字（没有未传的就不显示黄卡）
    static func warning(pending n: Int, cashier: Bool) -> String? {
        guard n > 0 else { return nil }
        return cashier ? "还有 \(n) 笔待传。先别删 App，让家里人重新出一个收银员码，扫了以后会自动补传"
            : "还有 \(n) 笔待传，没网传不了。先别删 App，连上网重新登录会自动补传"
    }
}

/// 25b（家用）/ 25f（收银员）：这台手机已经退出登录（§4.5）
struct KickedView: View {
    let model: KickedModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Circle().fill(Tokens.Palette.card)
                        .overlay(Circle().strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                        .overlay(Image(systemName: "iphone").font(.system(size: 52, weight: .semibold)).foregroundStyle(Tokens.Palette.ink))
                        .frame(width: 96, height: 96)
                        .padding(.top, 72)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("这台手机已经退出登录").font(TypeScale.title).multilineTextAlignment(.center)
                            .accessibilityIdentifier("kicked.title")
                        Text("家里人在「已登录的手机」里让它退出了").font(TypeScale.secondary)
                            .foregroundStyle(Tokens.Palette.ink2).multilineTextAlignment(.center)
                    }
                    if let w = KickedModel.warning(pending: model.pending, cashier: model.cashier) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 24, weight: .bold))
                            Text(w).font(TypeScale.body.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Tokens.Palette.ink)
                        .padding(18)
                        .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("kicked.pending")
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
            PrimaryButton(model.cashier ? "扫家里人给的码" : "重新登录", style: .dark) { model.next() }
                .padding(.horizontal, 20).padding(.bottom, 12)
                .accessibilityIdentifier("kicked.continue")
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)   // 页面的 id 不盖住里面按钮的 id
        .accessibilityIdentifier(model.cashier ? "page.kickedCashier" : "page.kicked")
    }
}

/// 退出登录（设置 → 退出登录，§4.5）：先确认；确认后把没传的传完再注销。没网时提示「还有 N 笔待传，联网后会自动补传」。
/// S23a 换成 26 号通用确认面板，排空流程不变。
struct LogoutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    enum Phase: Equatable { case confirm, working, pending(Int) }
    @State private var phase = Phase.confirm
    /// 26 通用确认面板：进这一页就弹（S23a）；「不退了」或把面板拉下去 = 回到上一页
    struct Ask: Identifiable { let id = 0 }
    @State private var ask: Ask? = Ask()

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.logout.title(model.layout), mode: Route.logout.mode, onBack: { if phase == .confirm { dismiss() } })
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .confirmSheet(item: $ask) { _ in
            ConfirmPanel(title: "退出登录？", message: "退出以后，这台手机上的账要重新登录才能看。待传的账会先传上去。",
                         confirmTitle: "退出登录", cancelTitle: "不退了", mode: .neutral,
                         confirmStyle: .dark, confirmImage: nil, confirmId: "logout.confirm", cancelId: "logout.cancel",
                         busy: phase != .confirm,
                         // 面板收起的动画里再点一下不会再退一次
                         onConfirm: { guard phase == .confirm else { return }; phase = .working; ask = nil; Task { await run() } },
                         onCancel: { ask = nil })
        }
        .onChange(of: ask == nil) { _, closed in
            if closed, phase == .confirm { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.logout")
    }

    @ViewBuilder private var content: some View {
            switch phase {
            case .confirm:
                Spacer()   // 确认在 26 面板里
            case .working:
                HStack(spacing: 12) { ProgressView(); Text("正在把待传的账传上去…").font(TypeScale.body) }
                Spacer()
            case .pending(let n):
                Text(n > 0 ? "还有 \(n) 笔待传，联网后会自动补传" : "没连上服务器，联网后会自动退出")
                    .font(TypeScale.body.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    .accessibilityIdentifier("logout.pending")
                Text("先别删 App。").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                Spacer()
                PrimaryButton("知道了", style: .dark) { finish() }
                    .accessibilityIdentifier("logout.ok")
            }
    }

    private func run() async {
        phase = .working
        switch await model.logout() {
        case .done, .kicked: finish()   // 被踢：AppRoot 按退出原因进 25b / 25f
        case .pending(let n): phase = .pending(n)
        }
    }

    private func finish() {
        NotificationCenter.default.post(name: AppRoot.signedOut, object: model.db)
    }
}
