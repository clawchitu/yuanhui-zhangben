import Charts
import ShopCore
import SwiftUI

/// 09 / 10 看账：「今天」「本月」两栏。数字全部是服务器给的（§5.3），手机只排版。
/// 账只在服务器上：没网、没连上就只显示「要联网才能看账」，不显示空白或上一次的数。
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reports: ReportsModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.reports.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let reports {
                ReportsTabs(reports: reports, offline: model.offline)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                ScrollView {
                    ReportsContent(reports: reports, now: model.now)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await reports.load(offline: model.offline) }
            } else {
                // 没有网络服务（夹具没给桩）：和没网一样
                ScrollView { ReportsOffline(retry: nil).padding(.horizontal, 20) }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if reports == nil { reports = model.makeReportsModel() }
            Task { await reports?.load(offline: model.offline) }
        }
        .onChange(of: model.offline) { _, off in
            Task { await reports?.networkChanged(offline: off) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.reports.pageId)
    }
}

/// 「今天 | 本月」切换（稿子上的大块分段）
private struct ReportsTabs: View {
    let reports: ReportsModel
    let offline: Bool

    var body: some View {
        HStack(spacing: 6) {
            tab(.today, "今天")
            tab(.month, "本月")
        }
        .padding(6)
        .background(Tokens.Palette.line.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
    }

    private func tab(_ t: ReportsModel.Tab, _ title: String) -> some View {
        let on = reports.tab == t
        return Button {
            Task { await reports.select(t, offline: offline) }
        } label: {
            Text(title)
                .font(.system(size: 26, weight: on ? .bold : .regular))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(on ? Tokens.Palette.card : .clear, in: RoundedRectangle(cornerRadius: 15))
                .shadow(color: on ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("reports.tab.\(t.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct ReportsContent: View {
    let reports: ReportsModel
    let now: Date

    var body: some View {
        switch reports.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityIdentifier("reports.loading")
        case .offline:
            ReportsOffline(retry: { Task { await reports.load(offline: false) } })
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 16) {
                Text(msg).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reports.error")
                RetryButton { Task { await reports.load(offline: false) } }
                RecordsLink()
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .today(let r):
            TodayReport(r: r, showsNow: reports.showsNow, units: reports.units)
        case .month(let m):
            MonthReport(m: m, today: ReportLabels.shanghaiDay(now), current: reports.monthParam == nil)
        }
    }
}

/// 没网：一句话 + 「再试一次」；记的账在本机，照样能进（家用首页没有提醒条时从这里进，§14 S15-6）
private struct ReportsOffline: View {
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("要联网才能看账")
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
                .accessibilityIdentifier("reports.offline")
            Text("账在服务器上，连上网就能看。记的账在这台手机上，不联网也能看。")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let retry { RetryButton(action: retry) }
            RecordsLink()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「记的账」入口（记的账在本机，看账取不到时照样进得去）
private struct RecordsLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink(value: Route.records) {
            Label(Route.records.title(model.layout), systemImage: "list.bullet.rectangle")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 64)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("reports.records")
    }
}

private struct RetryButton: View {
    let action: () -> Void
    var body: some View {
        PrimaryButton("再试一次", mode: .neutral, style: .dark, size: .small, action: action)
            .accessibilityIdentifier("reports.retry")
    }
}

// MARK: - 09 今天

private struct TodayReport: View {
    let r: ReportToday
    let showsNow: Bool
    let units: [UUID: String]

    private var dayTitle: String {
        guard !showsNow, let d = try? CalendarDate(r.date) else { return "今天" }
        return "\(d.month)月\(d.day)日"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BigAmount(caption: "\(dayTitle)卖了（实收）", fen: r.soldFen)
            StatRow {
                StatCard(title: "赚了", value: ReportFormat.money(r.profitFen), fen: r.profitFen.raw, id: "reports.profit")
                NavigationLink(value: Route.records) {
                    StatCard(title: "记了", value: "\(r.count) 笔", fen: Int64(r.count), id: "reports.count", chevron: true)
                }
                .buttonStyle(PressDimStyle())
                // 卡片是按钮，里面的字合成一个元素：笔数放在按钮自己的 label / value 上
                .accessibilityLabel("记了 \(r.count) 笔")
                .accessibilityValue(String(r.count))
                .accessibilityIdentifier("reports.records")
                // 没有优惠时不显示优惠卡
                if r.discountFen.raw != 0 {
                    StatCard(title: "优惠", value: ReportFormat.money(r.discountFen), fen: r.discountFen.raw, id: "reports.discount")
                }
            }
            .padding(.top, 10)
            ProfitNote(costMissing: r.costMissingCount, lossMissing: r.lossCostMissingCount)
            TopSellers(items: r.topSellers)
            if showsNow {
                LowStock(items: r.lowStock, units: units)
                Expiring(items: r.expiring, today: r.date)
            }
        }
    }
}

/// 「今天卖了（实收）」+ 大数字
private struct BigAmount: View {
    let caption: String
    let fen: Fen

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("¥").font(TypeScale.number(40))
                Text(ReportFormat.yuan(fen)).font(TypeScale.number(64))
            }
            .foregroundStyle(Tokens.Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReportFormat.money(fen))
            .accessibilityValue(String(fen.raw))
            .accessibilityIdentifier("reports.sold")
        }
        .padding(.top, 4)
    }
}

/// 一排小卡片；辅助功能大字号（放不下）时一张一行
private struct StatRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) { content() }
        } else {
            HStack(spacing: 10) { content() }
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    /// 接口里的原值（整数分 / 笔数），放进辅助功能的 value，测试逐分核对
    let fen: Int64
    let id: String
    var chevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.ink2).accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            YuanText(text: value, size: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(value)
                .accessibilityValue(String(fen))
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
    }
}

/// 「¥5,487」：¥ 小一号（稿子 09 / 10 的卡片）；窄了数字整体缩小，不截断
private struct YuanText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if text.hasPrefix("¥") {
                Text("¥").font(TypeScale.number(size * 0.65))
                Text(text.dropFirst()).font(TypeScale.number(size))
            } else {
                Text(text).font(TypeScale.number(size))
            }
        }
        .foregroundStyle(Tokens.Palette.ink)
        .lineLimit(1)
        // 金额长（窄屏、大字）时整体缩小，不出「…」：显示的数必须完整
        .minimumScaleFactor(0.4)
    }
}

/// 口径小字；有没填进价的卖出、没算进价的损耗时再加一句
private struct ProfitNote: View {
    let costMissing: Int
    let lossMissing: Int

    static let formula = "赚了 = 卖出 − 进价，损耗和盘点少的另算"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.formula)
                .accessibilityIdentifier("reports.formula")
            if costMissing > 0 {
                Text("有 \(costMissing) 样进价没填，卖的钱没算进「赚了」")
                    .foregroundStyle(Tokens.Palette.sell)
                    .accessibilityIdentifier("reports.costMissing")
            }
            if lossMissing > 0 {
                Text("有 \(lossMissing) 笔损耗没算进价")
                    .foregroundStyle(Tokens.Palette.sell)
                    .accessibilityIdentifier("reports.lossMissing")
            }
        }
        .font(TypeScale.secondary)
        .foregroundStyle(Tokens.Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}

private struct SectionHeader: View {
    let title: String
    let trailing: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(TypeScale.title.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: 8)
            Text(trailing).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
        }
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

private struct TopSellers: View {
    let items: [ReportProductAmount]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "卖得最好", trailing: "卖出个数")
            if items.isEmpty {
                Text("还没卖出东西").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                    .accessibilityIdentifier("reports.top.none")
            }
            let top = max(items.compactMap(\.qty).max() ?? 1, 1)
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 12) {
                    Text(it.name).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    // 横条（一律朱红，长短按个数）
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Tokens.Palette.sell)
                        .frame(width: 90 * CGFloat(max(it.qty ?? 0, 0)) / CGFloat(top), height: 26)
                        .frame(width: 90, alignment: .leading)
                        .accessibilityHidden(true)
                    Text("\(it.qty ?? 0)").font(TypeScale.number(30)).foregroundStyle(Tokens.Palette.ink)
                        .frame(minWidth: 48, alignment: .trailing)
                        .fixedSize()
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(it.name) \(it.qty ?? 0)")
                .accessibilityValue(String(it.qty ?? 0))
                .accessibilityIdentifier("reports.top.\(i)")
            }
        }
    }
}

/// 快没货：库存 ≤ 0 显示「没货了」（§14 S07-6）。最多列 5 种，标题写一共几种
private struct LowStock: View {
    let items: [ReportProductAmount]
    let units: [UUID: String]
    static let shown = 5

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "快没货了", trailing: "共 \(items.count) 种")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("reports.low.header")
                ForEach(Array(items.prefix(Self.shown).enumerated()), id: \.offset) { i, it in
                    let qty: Int64 = it.qty ?? 0
                    let label: String = ReportLabels.lowStock(qty: it.qty, unit: units[it.productId])
                    let icon: String? = qty <= 0 ? nil : "exclamationmark.triangle"
                    ListRow(name: it.name, id: "reports.low.\(i)", value: String(qty)) {
                        ReportPill(text: label, icon: icon, dark: qty <= 0)
                    }
                }
            }
        }
    }
}

/// 快过期：按商品合并（服务器已合并）。列前 2 样，「共 N 样 ›」进 19
private struct Expiring: View {
    let items: [ReportProductAmount]
    let today: String
    static let shown = 2

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink(value: Route.expiry) {
                    SectionHeader(title: "快过期了", trailing: "共 \(items.count) 样 ›")
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("reports.expiring.header")
                ForEach(Array(items.prefix(Self.shown).enumerated()), id: \.offset) { i, it in
                    let label = ReportLabels.expiring(it.expiryDate, today: today)
                    ListRow(name: it.name, id: "reports.expiring.\(i)", value: it.expiryDate ?? "") {
                        ReportPill(text: label, icon: nil, dark: label == "已过期")
                    }
                }
            }
        }
    }
}

private struct ListRow<Trailing: View>: View {
    let name: String
    let id: String
    let value: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(name).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    trailing()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    trailing()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }
}

/// 黄底标签（「⚠ 还剩 2 罐」「2 天后」）；「没货了」「已过期」黑底白字
private struct ReportPill: View {
    let text: String
    let icon: String?
    let dark: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 20, weight: .bold)).accessibilityHidden(true) }
            Text(text).font(.system(size: 24, weight: .bold))
        }
        .foregroundStyle(dark ? .white : Tokens.Palette.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(dark ? Tokens.Palette.ink : Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }
}

// MARK: - 10 本月

private struct MonthReport: View {
    let m: ReportMonth
    let today: String
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BigAmount(caption: "\(m.monthTitle)卖了（\(current ? "到今天，" : "")实收）", fen: m.soldFen)
            StatRow {
                StatCard(title: "赚了", value: ReportFormat.money(m.profitFen, compact: true), fen: m.profitFen.raw, id: "reports.profit")
                StatCard(title: "进货花了", value: ReportFormat.money(m.stockInFen, compact: true), fen: m.stockInFen.raw, id: "reports.stockIn")
                // §14 S07-4：取 stock_value_end_fen
                StatCard(title: "店里货值", value: ReportFormat.money(m.stockValueEndFen, compact: true), fen: m.stockValueEndFen.raw,
                         id: "reports.stockValue")
            }
            .padding(.top, 10)
            ProfitNote(costMissing: m.costMissingCount, lossMissing: m.lossCostMissingCount)
            StatRow {
                if m.discountFen.raw != 0 {
                    WideStat(title: "优惠", fen: m.discountFen, id: "reports.discount")
                }
                WideStat(title: "过期损耗", fen: m.expireLossFen, id: "reports.expireLoss")
            }
            .padding(.top, 10)
            DailyChart(m: m, today: today)
            Reconciliation(m: m, current: current)
        }
    }
}

/// 「优惠 ¥46」「过期损耗 ¥58」这种一行的卡
private struct WideStat: View {
    let title: String
    let fen: Fen
    let id: String

    var body: some View {
        HStack {
            Text(title).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(ReportFormat.money(fen, compact: true)).font(TypeScale.number(30)).foregroundStyle(Tokens.Palette.ink)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ReportFormat.money(fen, compact: true))
                .accessibilityValue(String(fen.raw))
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
    }
}

/// 每天卖多少：单色柱子，今天朱红、其余灰（S24）；点一根柱子在上面写那天卖了多少，再点一次收起
private struct DailyChart: View {
    let m: ReportMonth
    let today: String
    @State private var selected: Int?

    private var bars: [DayBar] { DayBar.bars(m, today: today) }

    var body: some View {
        let bars = bars
        let todayBar = bars.first(where: \.isToday)
        let maxBar = bars.filter { $0.soldFen > 0 }.max { $0.soldFen < $1.soldFen }
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { title; Spacer(minLength: 4); legend(todayBar, maxBar) }
                VStack(alignment: .leading, spacing: 4) { title; legend(todayBar, maxBar) }
            }
            Group {
                if let s = selected, let b = bars.first(where: { $0.day == s }) {
                    Text("\(m.monthTitle)\(b.day)日卖了 \(ReportFormat.money(Fen(b.soldFen)))")
                        .foregroundStyle(Tokens.Palette.ink)
                        .accessibilityValue(String(b.soldFen))
                        .accessibilityIdentifier("reports.chart.selected")
                } else {
                    Text("点柱子看那天卖了多少").foregroundStyle(Tokens.Palette.ink2)
                }
            }
            .font(TypeScale.secondary)
            chart(bars)
        }
        .padding(.top, 22)
    }

    private var title: some View {
        Text("每天卖多少").font(TypeScale.title.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
    }

    private func legend(_ t: DayBar?, _ mx: DayBar?) -> some View {
        HStack(spacing: 12) {
            if let t {
                dot(Tokens.Palette.sell, "今天 \(ReportFormat.compact(Fen(t.soldFen)))")
                    .accessibilityIdentifier("reports.chart.today")
            }
            if let mx {
                dot(Tokens.Palette.mute, "最多 \(ReportFormat.compact(Fen(mx.soldFen)))")
                    .accessibilityIdentifier("reports.chart.max")
            }
        }
        .font(TypeScale.secondary)
        .foregroundStyle(Tokens.Palette.ink2)
    }

    private func dot(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 14, height: 14)
            Text(s).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ bars: [DayBar]) -> some View {
        let days = m.daysInMonth
        let ticks = [1, 10, 20, days >= 30 ? 30 : days]
        return Chart(bars) { b in
            BarMark(x: .value("日", b.day), y: .value("卖了", Int(b.soldFen)), width: .fixed(7))
                .foregroundStyle(b.isToday ? Tokens.Palette.sell : Tokens.Palette.mute)
                .opacity(selected == nil || selected == b.day ? 1 : 0.55)
                .accessibilityLabel("\(b.day)日")
                .accessibilityValue(ReportFormat.money(Fen(b.soldFen)))
        }
        .chartXScale(domain: 0...(days + 2))
        .chartXAxis {
            AxisMarks(values: ticks) { v in
                // 月底那个刻度贴着右边，默认的避让会把它藏掉
                AxisValueLabel(collisionResolution: .disabled) {
                    if let d = v.as(Int.self) {
                        Text("\(d)").font(.system(size: ReportLabels.axisFontSize, weight: .medium)).foregroundStyle(Tokens.Palette.ink2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Tokens.Palette.line)
                AxisValueLabel {
                    if let f = v.as(Int.self) {
                        Text(ReportFormat.compact(Fen(Int64(f)))).font(.system(size: ReportLabels.axisFontSize, weight: .medium))
                            .foregroundStyle(Tokens.Palette.ink2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard let plot = proxy.plotFrame else { return }
                        let x = loc.x - g[plot].origin.x
                        guard let raw: Int = proxy.value(atX: x) else { return }
                        // 点在两根柱子之间也算最近的那一根
                        guard let near = bars.min(by: { abs($0.day - raw) < abs($1.day - raw) }), abs(near.day - raw) <= 1 else { return }
                        selected = selected == near.day ? nil : near.day
                    }
            }
        }
        .frame(height: 190)
        .padding(.trailing, 10)
        .accessibilityIdentifier("reports.chart")
    }
}

/// 进货对账：各行相加等于最后一行（§5.3 I6）
private struct Reconciliation: View {
    let m: ReportMonth
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("进货对账").font(TypeScale.title.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                .padding(.top, 22).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(m.reconLines.enumerated()), id: \.element.id) { i, line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if let verb = line.verb { Text(verb).frame(minWidth: 30, alignment: .leading) }
                            Text(line.label).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(ReportFormat.compact(line.shown)).font(TypeScale.number(28)).fixedSize()
                        }
                        .font(TypeScale.body)
                        .foregroundStyle(Tokens.Palette.ink)
                        if line.costMissing > 0 {
                            Text("有 \(line.costMissing) 笔没算进价").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(String(line.signed))
                    .accessibilityIdentifier("reports.recon.\(i)")
                }
                Rectangle().fill(Tokens.Palette.ink).frame(height: 1.5).padding(.vertical, 2)
                HStack(alignment: .firstTextBaseline) {
                    Text(current ? "现在店里货值" : "\(m.monthTitle)底店里货值").font(TypeScale.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(ReportFormat.compact(m.reconciliation.stockValueEndFen)).font(TypeScale.number(32)).fixedSize()
                }
                .foregroundStyle(Tokens.Palette.ink)
                .accessibilityElement(children: .combine)
                .accessibilityValue(String(m.reconciliation.stockValueEndFen.raw))
                .accessibilityIdentifier("reports.recon.end")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
        }
    }
}
