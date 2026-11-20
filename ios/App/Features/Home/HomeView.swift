import ShopCore
import SwiftUI

/// 首页：家用 = 01（卖出、进货、看账 / 商品 / 更多、提醒条、刚记的），收银员 = 02（只有卖出、我刚记的、齿轮）。
/// 入口按能力表出（§6.2）；25a 的「没传上去」提醒条在「快过期」上面。
/// 大卡片、三个小按钮、「记错了」是固定尺寸（主按钮类），其余文字走动态字号；放不下时整页可以滚动。
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var caps: Capabilities { model.capabilities }
    private var isCashierLayout: Bool { !caps.has(.stockIn) }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: model.session.storeName, pendingCount: model.figures.pendingCount)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        FillHeightLayout(minHeight: geo.size.height) {
                            content
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                                .padding(.bottom, 10)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .task {
                        guard model.scrollToBottom else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        proxy.scrollTo("home.bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.home")
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 12) {
            dateRow.fixedSize(horizontal: false, vertical: true)
            ForEach(HomeReminder.list(model.figures, capabilities: caps), id: \.self) { reminderBanner($0) }
            if caps.has(.sell) {
                HomeActionCard(route: .sell, title: "卖出", subtitle: isCashierLayout ? "顾客买东西，点这里扫码\n抹零也在这里面" : "顾客买东西，点这里扫码",
                               systemImage: "barcode.viewfinder", color: Tokens.Palette.sell, big: isCashierLayout)
                    .frame(minHeight: isCashierLayout ? 260 : 150, maxHeight: isCashierLayout ? .infinity : 195)
            }
            if caps.has(.stockIn) {
                HomeActionCard(route: .stockIn, title: "进货", subtitle: "货送到了，点这里扫码",
                               systemImage: "shippingbox", color: Tokens.Palette.stock, big: false)
                    .frame(minHeight: 150, maxHeight: 195)
            }
            smallButtons
            if !isCashierLayout { Spacer(minLength: 0) }
            if let r = model.figures.lastRecord { RecentCard(record: r, cashier: isCashierLayout) }
            Color.clear.frame(height: 0).id("home.bottom")
        }
    }

    // MARK: 日期行

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: model.today)
    }

    @ViewBuilder private var dateRow: some View {
        let date = Text(dateText).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
        if isCashierLayout {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    date
                    Text("收银员 · \(model.session.deviceLabel)")
                        .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(width: Tokens.Size.minHitTarget, height: Tokens.Size.minHitTarget)
                        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                }
                .buttonStyle(PressDimStyle())
                .accessibilityLabel("设置")
                .accessibilityIdentifier("home.settings")
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    date.fixedSize()
                    Spacer(minLength: 12)
                    deviceLabel.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    date
                    deviceLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var deviceLabel: some View {
        Text(model.session.deviceLabel).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
    }

    // MARK: 提醒条

    @ViewBuilder private func reminderBanner(_ r: HomeReminder) -> some View {
        switch r {
        case .unsynced(let n):
            NavigationLink(value: Route.records) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "wifi.slash").font(.system(size: 22, weight: .semibold))
                    Text("\(n) 笔超过一天没传上去")
                        .font(TypeScale.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(minHeight: 60)
                .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.banner).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .fixedSize(horizontal: false, vertical: true)  // 辅助字号下文字换行时提醒条跟着长高，不被压扁
            .accessibilityIdentifier("home.banner.unsynced")
        case .expiring(let n):
            NavigationLink(value: Route.expiry) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .bold))
                    Text("有 \(n) 样快过期了")
                        .font(TypeScale.body.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text("去看").font(TypeScale.body.weight(.medium)).fixedSize()
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
                .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("home.banner.expiring")
        }
    }

    // MARK: 看账 / 商品 / 更多

    @ViewBuilder private var smallButtons: some View {
        let items: [(Route, String)] = [(.reports, "看账"), (.products, "商品"), (.settings, "更多")]
            .filter { $0.0.isAllowed(caps) && !(isCashierLayout && $0.0 == .settings) }
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.0) { route, title in
                    NavigationLink(value: route) {
                        Text(title)
                            .font(.system(size: 24, weight: .bold))
                            .lineLimit(1)
                            .foregroundStyle(Tokens.Palette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 63)
                            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle())
                    .accessibilityIdentifier(route == .settings ? "home.more" : "home.\(route.rawValue)")
                }
            }
        }
    }
}

/// 首页的大卡片（卖出 / 进货）。字号固定；卡片高度可伸缩，最小高度保证文字不被截断。
struct HomeActionCard: View {
    let route: Route
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    /// 收银员首页的卖出卡更大（02）
    let big: Bool

    private var titleSize: CGFloat { big ? 78 : 64 }
    private var circle: CGFloat { big ? 110 : 88 }

    var body: some View {
        NavigationLink(value: route) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: titleSize, weight: .heavy))
                        .tracking(big ? 12 : 9)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.top, big ? 22 : 18)
                    Spacer(minLength: 6)
                    Text(subtitle)
                        .font(.system(size: 22, weight: .regular))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.bottom, 22)
                }
                .padding(.leading, big ? 30 : 26)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: circle, height: circle)
                    .overlay(Image(systemName: systemImage).font(.system(size: circle * 0.48, weight: .medium)))
                    .padding(.top, big ? 23 : 20)
                    .padding(.trailing, big ? 24 : 20)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(PressDimStyle())
        .accessibilityLabel("\(title)，\(subtitle.replacingOccurrences(of: "\n", with: "，"))")
        .accessibilityIdentifier("home.\(route.rawValue)")
    }
}

/// 「刚记的」条。家用：刚记的 + 记错了；收银员：我刚记的 · 点开看（进 07b）+ 记错了。
struct RecentCard: View {
    @Environment(AppModel.self) private var model
    let record: HomeFigures.LastRecord
    let cashier: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                summary
                Spacer(minLength: 0)
                undo
            }
            VStack(alignment: .leading, spacing: 12) {
                summary
                undo
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
            .strokeBorder(cashier ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: cashier ? 2.5 : 1.5))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.recent")
    }

    @ViewBuilder private var summary: some View {
        let body = VStack(alignment: .leading, spacing: 4) {
            Text(cashier ? "我刚记的 \(record.time) · 点开看" : "刚记的 \(record.time)")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(record.kind) \(record.itemCount) 样")
                    .font(TypeScale.body.weight(.bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize()
                PriceText(cents: record.amountFen, size: 26)
            }
        }
        if cashier {
            NavigationLink(value: Route.records) { body.contentShape(Rectangle()) }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("home.records")
        } else {
            body
        }
    }

    @ViewBuilder private var undo: some View {
        if Route.undoLast.isAllowed(model.capabilities) {
            NavigationLink(value: Route.undoLast) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("记错了")
                }
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Tokens.Size.minHitTarget)
                    .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .fixedSize()
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("home.undo")
        }
    }
}

/// 放在 ScrollView 里：内容至少和可视区一样高（大卡片可以撑满），内容放不下时按最小高度排、整页滚动。
/// （ScrollView 不给子视图提议高度，`frame(minHeight:)` 撑不开里面可伸缩的卡片，所以自己量。）
struct FillHeightLayout: Layout {
    var minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let width = proposal.width ?? s.sizeThatFits(.unspecified).width
        let least = s.sizeThatFits(ProposedViewSize(width: width, height: 0)).height
        return CGSize(width: width, height: max(minHeight, least))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
