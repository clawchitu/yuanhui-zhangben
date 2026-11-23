import ShopCore
import SwiftUI

/// 07a 记的账（家用：今天 / 昨天 / 更早）、07b 我今天记的（收银员）、07c 更早（每天一行）、08 撤销。
/// `undoLast`：从首页「记错了」进来，直接对最近一张能撤的卡打开 08。
struct RecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: RecordsModel
    let route: Route
    let undoLast: Bool

    init(db: LocalDB, cashier: Bool, route: Route, clock: @escaping () -> Date) {
        _model = State(initialValue: RecordsModel(db: db, cashier: cashier, clock: clock))
        self.route = route
        self.undoLast = route == .undoLast
    }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: model.cashier ? "我今天记的" : "记的账", pendingCount: app.sync == nil ? model.pendingCount : app.figures.pendingCount,
                    offline: app.offline, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.cashier { tabs }
                    Text(hint)
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let n = model.notice { noticeRow(n) }
                    if model.showsDayList { dayList } else { cardList }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .sheet(item: $model.undoCard) { card in
            UndoSheet(card: card, canUndo: model.canUndo(card), onUndoLine: { model.undo(.entry($0)) },
                      onUndoAll: { model.undoAll(card) }, onCancel: { model.undoCard = nil })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            let a = app
            model.onChange = { a.refreshRecent() }
            if undoLast { model.openLatestUndo() }
            #if DEBUG
            // 截图 / UI 测试：-uiRecordsTab yesterday|earlier [-uiRecordsDay 0]
            let args = ProcessInfo.processInfo.arguments
            if let t = UIFixture.value(for: "-uiRecordsTab", in: args).flatMap(RecordsModel.Tab.init(rawValue:)) { model.tab = t }
            if let i = UIFixture.value(for: "-uiRecordsDay", in: args).flatMap(Int.init), i < model.visibleDays.count {
                model.openDay = model.visibleDays[i].day
            }
            #endif
        }
        // 每同步完一趟重取：拉下来的服务器行换掉本机的临时行、被拒的标「没记上」
        .onChange(of: app.sync?.rounds) { _, _ in model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(route.pageId)
    }

    private var hint: String {
        if model.cashier { return "只能撤这台手机今天记的卖出。昨天的找家里人" }
        if model.showsDayList { return "点哪天看哪天，撤销和今天一样" }
        if let d = model.openDay { return "\(RecordsModel.dayTitle(d))，记错了就点「撤销」" }
        return "记错了就点「撤销」，再重新记一遍"
    }

    // MARK: 今天 / 昨天 / 更早

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(RecordsModel.Tab.allCases, id: \.self) { t in
                let on = model.tab == t
                Button { model.tab = t; if t == .earlier { model.openDay = nil } } label: {
                    Text(t == .today ? "今天" : t == .yesterday ? "昨天" : "更早")
                        .font(.system(size: 22, weight: on ? .bold : .medium))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.minHitTarget)
                        .background(on ? Tokens.Palette.card : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("records.tab.\(t.rawValue)")
            }
        }
        .padding(4)
        .background(Color(hex: 0xDDD6C6), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var cardList: some View {
        if model.cards.isEmpty {
            Text(model.cashier ? "今天还没记账" : "这天没有记账")
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink2)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .accessibilityIdentifier("records.empty")
        }
        ForEach(Array(model.cards.enumerated()), id: \.element.id) { i, card in
            RecordCardView(card: card, showDevice: !model.cashier, canUndo: model.canUndo(card)) { model.undoCard = card }
                .accessibilityIdentifier("records.card.\(i)")
        }
    }

    // MARK: 07c

    @ViewBuilder private var dayList: some View {
        if model.days.isEmpty {
            Text("前几天没有记账").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                .frame(maxWidth: .infinity).padding(.top, 40)
        }
        VStack(spacing: 0) {
            ForEach(Array(model.visibleDays.enumerated()), id: \.element.id) { i, d in
                Button { model.openDay = d.day } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) { dayLabel(d); Spacer(minLength: 8); dayAmount(d) }
                        VStack(alignment: .leading, spacing: 4) { dayLabel(d); HStack { Spacer(); dayAmount(d) } }
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("records.day.\(i)")
                Divider().overlay(Tokens.Palette.line)
            }
        }
        if model.hasMoreDays {
            Button { model.moreDays() } label: {
                Text("再往前 7 天").font(.system(size: 24, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("records.more")
        } else if !model.days.isEmpty {
            Text("手机上只留最近 \(LocalDB.familyLedgerDays) 天的账，更早的要联网看")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("records.offlineLimit")
        }
    }

    private func dayLabel(_ d: LedgerDay) -> some View {
        let parts = RecordsModel.dayTitle(d.day).split(separator: " ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(parts[0])).font(.system(size: 24, weight: .bold)).foregroundStyle(Tokens.Palette.ink).fixedSize()
            Text("\(parts[1]) \(d.count) 笔").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dayAmount(_ d: LedgerDay) -> some View {
        HStack(spacing: 8) {
            // 07c 的金额带千分位（¥1,102.00）
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("¥").font(TypeScale.number(17))
                Text(RecordsModel.grouped(d.saleFen)).font(TypeScale.number(28))
            }
            .foregroundStyle(Tokens.Palette.ink).lineLimit(1).fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel("\(Money.yuanString(Int(d.saleFen))) 元")
            Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(Tokens.Palette.ink)
        }
    }

    private func noticeRow(_ n: String) -> some View {
        Text(n)
            .font(TypeScale.body.weight(.medium))
            .foregroundStyle(Tokens.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
            .onTapGesture { model.dismissNotice() }
            .accessibilityIdentifier("records.notice")
    }
}

/// 07a / 07b 的一张卡
struct RecordCardView: View {
    let card: RecordCard
    let showDevice: Bool
    let canUndo: Bool
    let onUndo: () -> Void

    private var struck: Bool { card.allVoided }
    private var markerColor: Color {
        switch card.type {
        case .sale: Tokens.Palette.sell
        case .stockIn: Tokens.Palette.stock
        default: Tokens.Palette.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(card.lines) { l in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(l.name).font(TypeScale.body).strikethrough(l.voided)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(l.quantityText).font(.system(size: 24, weight: .semibold)).strikethrough(l.voided).fixedSize()
                }
                .foregroundStyle(l.voided ? Tokens.Palette.ink2 : Tokens.Palette.ink)
            }
            TrailingAccessoryLayout(spacing: 12) {
                amount
                trailing
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(struck ? Color.clear : Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
            .strokeBorder(Tokens.Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: struck ? [6, 5] : [])))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if card.type == .sale || card.type == .stockIn {
                    RoundedRectangle(cornerRadius: card.type == .sale ? 3 : 8).fill(markerColor).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "diamond.fill").font(.system(size: 16)).foregroundStyle(markerColor)
                }
            }
            .accessibilityHidden(true)
            Text(card.kindText).font(.system(size: 24, weight: .bold)).fixedSize()
            Text(card.time).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2).fixedSize()
            if card.rejected {
                // 服务器拒收了（收银员越权、商品不存在……）：这笔没记上，库存已按服务器纠正（S22a）
                Text("没记上").font(TypeScale.secondary.weight(.bold)).foregroundStyle(Tokens.Palette.sell)
                    .fixedSize()
                    .accessibilityIdentifier("records.rejected")
            }
            if showDevice {
                Text(card.deviceLabel).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("records.device")
            }
        }
        .foregroundStyle(Tokens.Palette.ink)
    }

    @ViewBuilder private var amount: some View {
        VStack(alignment: .leading, spacing: 2) {
            if card.partlyVoided {
                Text("撤了一部分，还剩").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if card.type == .sale, card.discountFen != 0, let l = card.listTotalFen {
                (Text("原价 ") + Text("¥\(Money.yuanString(Int(l)))").strikethrough() + Text("    实收"))
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            } else if card.type == .expireLoss || card.type == .supplierReturn, card.amountFen != nil {
                Text("算亏（按进价）").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            }
            if let a = card.amountFen {
                PriceText(cents: Int(a), size: 40, color: struck ? Tokens.Palette.ink2 : Tokens.Palette.ink)
                    .overlay(struck ? Rectangle().fill(Tokens.Palette.ink2).frame(height: 2.5) : nil)
                    .accessibilityIdentifier("records.amount")
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if struck {
            Text("已撤销").font(.system(size: 22, weight: .bold)).foregroundStyle(Tokens.Palette.ink2).fixedSize()
                .accessibilityIdentifier("records.voided")
        } else if canUndo {
            Button(action: onUndo) {
                Label("撤销", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 64)
                    .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .fixedSize()
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("records.undo")
        }
    }
}

/// 08 撤销：「撤销哪一样？」每行摊后退多少、「只撤这样」「整笔都撤销」「不撤了」
struct UndoSheet: View {
    let card: RecordCard
    let canUndo: Bool
    let onUndoLine: (UUID) -> Void
    let onUndoAll: () -> Void
    let onCancel: () -> Void

    private var perLine: Bool { card.openLines.count > 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(perLine ? "撤销哪一样？" : "撤销这一笔？").font(.system(size: 30, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(RecordsModel.undoSubtitle(card)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = RecordsModel.discountNote(card) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(TypeScale.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                        .accessibilityIdentifier("undo.discountNote")
                }
                ForEach(Array(card.openLines.enumerated()), id: \.element.id) { i, l in
                    Divider().overlay(Tokens.Palette.line)
                    TrailingAccessoryLayout(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.name).font(TypeScale.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            Text(card.type == .sale ? "\(l.quantityText)    退 ¥\(Money.yuanString(Int(l.amountFen)))" : l.quantityText)
                                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("undo.refund.\(i)")
                        }
                        if perLine && canUndo {
                            Button { onUndoLine(l.id) } label: {
                                Text("只撤这样").font(.system(size: 22, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                                    .padding(.horizontal, 18).frame(minHeight: 60)
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                                    .fixedSize()
                            }
                            .buttonStyle(PressDimStyle())
                            .accessibilityIdentifier("undo.line.\(i)")
                        }
                    }
                }
                if canUndo {
                    Button(action: onUndoAll) {
                        Label(perLine ? "整笔都撤销" : "撤销这一笔", systemImage: "arrow.uturn.backward")
                            .font(.system(size: Tokens.FixedFontSize.primaryButton, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.primaryButton)
                            .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
                    }
                    .buttonStyle(PressDimStyle())
                    .accessibilityIdentifier("undo.all")
                } else {
                    Text("这笔不能在这台手机上撤，找家里人").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                }
                Button(action: onCancel) {
                    Text("不撤了").font(.system(size: Tokens.FixedFontSize.primaryButton, weight: .bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.primaryButtonMedium)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("undo.cancel")
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(20)
        }
        .background(Tokens.Palette.card.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo.sheet")
    }
}
