import ShopCore
import SwiftUI

/// 17a 给家人开通、17b 给收银员开通、25d 码过期（S23a）。
/// 家人页一进来就出码；收银员页先写称呼再出码。码 2 分钟有效、用过一次作废；每 2 秒问一次服务器有没有被扫。
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairing: PairingModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: pairing?.tab == .cashier ? "给收银员开通" : "给家人开通", pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let pairing {
                PairingContent(pairing: pairing)
            } else {
                OfflineNote(text: "要联网才能开通")
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if pairing == nil { pairing = model.makePairingModel() }
            pairing?.appear()
        }
        .onDisappear { pairing?.disappear() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.pairing.pageId)
    }
}

private struct PairingContent: View {
    @Bindable var pairing: PairingModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TabSwitch(tab: pairing.tab) { t in nameFocused = false; pairing.select(t) }
                if pairing.tab == .cashier { nameRow }
                if pairing.tab == .family || pairing.code != .idle { CodeCard(pairing: pairing) }
                if pairing.tab == .family {
                    (Text("对方用新手机打开元辉账本，点「扫家里人手机上的码」。")
                     + Text("扫了以后和你一样，什么都能看、都能改。").bold())
                        .font(TypeScale.body)
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    DeviceListSection(pairing: pairing)
                } else {
                    cashierRights
                    Text("不用给收银员密码。不让他用了，就在「已登录的手机」里让它退出。")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    /// 17b：先写个称呼 + 出码（没写称呼时灰）
    @ViewBuilder private var nameRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先写个称呼").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { nameField; issueButton.frame(width: 120) }
                VStack(spacing: 12) { nameField; issueButton }
            }
            if let hint = pairing.duplicateHint {
                Text(hint)
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.sell)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.duplicate")
            }
        }
    }

    private var nameField: some View {
        TextField("比如：小李", text: $pairing.cashierName)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: Tokens.Size.primaryButton)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit { if pairing.canIssueCashier { pairing.newCode() } }
            .accessibilityIdentifier("pairing.name")
    }

    private var issueButton: some View {
        PrimaryButton("出码", style: .dark) {
            nameFocused = false
            pairing.newCode()
        }
        .disabled(!pairing.canIssueCashier)
        .accessibilityIdentifier("pairing.issue")
    }

    private var cashierRights: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("收银员能：").bold() + Text("卖出、抹零、撤销自己当天记的"))
            (Text("看不到：").bold() + Text("账、进价、库存，也不能进货、改价、盘点"))
        }
        .font(TypeScale.body)
        .foregroundStyle(Tokens.Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}

/// 家人 | 收银员 两段切换（17a / 17b 顶上）
private struct TabSwitch: View {
    let tab: PairingModel.Tab
    let select: (PairingModel.Tab) -> Void

    var body: some View {
        HStack(spacing: 6) {
            item("家人", .family)
            item("收银员", .cashier)
        }
        .padding(6)
        .background(Color(hex: 0xDDD6C6), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private func item(_ title: String, _ t: PairingModel.Tab) -> some View {
        Button { select(t) } label: {
            Text(title)
                .font(.system(size: 26, weight: tab == t ? .bold : .regular))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.minHitTarget)
                .background(tab == t ? Tokens.Palette.card : .clear, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityAddTraits(tab == t ? .isSelected : [])
        .accessibilityIdentifier("pairing.tab.\(t == .family ? "family" : "cashier")")
    }
}

/// 码这一块：二维码 + 倒计时；过期（25d）；被扫了；出错
private struct CodeCard: View {
    let pairing: PairingModel

    var body: some View {
        VStack(spacing: 14) {
            switch pairing.code {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            case .showing(let t, _, let label):
                qr(t.qrPayload)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = pairing.remainingSeconds(at: pairing.serverNow())
                    caption(left: left, label: label)
                }
            case .expired:
                ZStack {
                    QRCodeView(payload: "YHZB1:expired", dimmed: true).frame(maxWidth: 240)
                    VStack(spacing: 18) {
                        Text("这个码过期了").font(.system(size: 30, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                            .accessibilityIdentifier("pairing.expired")
                        renewButton("换一个新码")
                    }
                }
                Text("0:00 已失效").font(TypeScale.body).foregroundStyle(Tokens.Palette.mute)
            case .used(let label):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Tokens.Palette.ink)
                    .accessibilityHidden(true)
                Text(label.map { "「\($0)」已经登录了" } ?? "对方已经登录了")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.used")
                renewButton("再出一个码")
            case .failed(let msg):
                Text(msg).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.error")
                renewButton("再试一次")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
    }

    @ViewBuilder private func qr(_ payload: String) -> some View {
        let v = QRCodeView(payload: payload).frame(maxWidth: 240)
            .accessibilityElement()
            .accessibilityLabel("开通二维码")
            .accessibilityIdentifier("pairing.qr")
        #if DEBUG
        // 联调测试从这里读出码，另一台（脚本）拿去兑（只在 Debug 编译）
        v.accessibilityValue(payload)
        #else
        v
        #endif
    }

    private func caption(left: Int, label: String?) -> some View {
        let digits = Text(PairingModel.clock(left)).font(TypeScale.number(30)).foregroundStyle(Tokens.Palette.ink)
        let text: Text = if let label {
            Text("给 ") + Text(label).font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink) + Text(" 的码　") + digits + Text(" 后失效")
        } else {
            digits + Text(" 后失效，用过一次也失效")
        }
        return text
            .font(TypeScale.body)
            .foregroundStyle(Tokens.Palette.ink2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("pairing.countdown")
    }

    private func renewButton(_ title: String) -> some View {
        Button { pairing.newCode() } label: {
            Label(title, systemImage: "arrow.uturn.backward")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(minHeight: 64)
                .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("pairing.renew")
    }
}

/// 没有网络服务（夹具里没给桩）时的一句话
struct OfflineNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(TypeScale.body)
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.top, 80)
            .padding(.horizontal, 20)
        Spacer()
    }
}
