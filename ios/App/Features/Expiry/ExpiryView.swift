import ShopCore
import SwiftUI

/// 19 快过期的：已过期 / 快过期 / 过几天再提醒的。每行「处理」开 20（已过期）/ 20b（没过期）面板。
/// 账上的个数是推算的，面板先问货架上实际还有几个，处理一律以人数的为准（§5.4）。
struct ExpiryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expiry: ExpiryModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.expiry.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            ScrollView {
                if let expiry {
                    ExpiryList(expiry: expiry)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if expiry == nil {
                let m = ExpiryModel(db: model.db, clock: { [model] in model.now })
                m.onWrite = { [model] in model.refreshPending(); model.refreshExpiring() }
                expiry = m
            }
            expiry?.load()
        }
        .onChange(of: model.sync?.rounds) { _, _ in
            expiry?.syncFinished()
        }
        .sheet(item: Binding(get: { expiry?.handling }, set: { expiry?.handling = $0 })) { item in
            PanelSheet { if let expiry { ExpiryPanel(expiry: expiry, item: item) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.expiry.pageId)
    }
}

/// 20 / 20b 的抽屉：一打开就整张拉满（四个选择和「先不处理」都看得见，稿子上就是整张），大字时可以滚动。
/// 抽屉是新的呈现层：挂上 `page.expiry`（S15 遍历靠它认页），把弹出时的字号带进去（同 `ConfirmSheetModifier`）
private struct PanelSheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Capsule().fill(Tokens.Palette.mute).frame(width: 44, height: 5)
                content()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Route.expiry.pageId)
            .padding(.top, 12)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Tokens.Palette.card)
        .dynamicTypeSize(typeSize)
        .presentationDetents([.large])
        .presentationCornerRadius(Tokens.Radius.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expiry.sheet")
    }
}

private struct ExpiryList: View {
    let expiry: ExpiryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let n = expiry.notice {
                Button { expiry.notice = nil } label: {
                    Banner(kind: .alert, text: n, systemImage: "exclamationmark.circle.fill")
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("expiry.notice")
                .padding(.top, 8)
            }
            Text("按到期日排，先处理最上面的。账上的个数是推算的，处理时以货架上数的为准")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 8)
            if let b = expiry.board {
                if b.isEmpty {
                    Text("现在没有快过期的")
                        .font(TypeScale.body)
                        .foregroundStyle(Tokens.Palette.ink)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("expiry.empty")
                }
                section(.expired, items: b.expired)
                section(.soon, items: b.soon)
                if !b.snoozed.isEmpty {
                    Text("过几天再提醒的")
                        .font(TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.ink2)
                        .padding(.top, 18)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("expiry.snoozed.header")
                    ForEach(Array(b.snoozed.enumerated()), id: \.element.id) { i, it in
                        Row(item: it, lines: [ExpiryModel.dateText(it.expiryDate) + "到期",
                                              it.snoozedUntil.map { ExpiryModel.dateText($0) + "再提醒" } ?? ""],
                            id: "expiry.snoozed.\(i)", action: nil)
                    }
                }
            }
        }
    }

    enum Kind: String { case expired, soon }

    @ViewBuilder private func section(_ kind: Kind, items: [ExpiryItem]) -> some View {
        if !items.isEmpty {
            HStack(spacing: 10) {
                Pill(text: kind == .expired ? "已过期" : "快过期", kind: kind == .expired ? .ink : .tag)
                Text("\(ExpiryBoard.kinds(items)) 样").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("expiry.\(kind.rawValue).header")
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                Row(item: it, lines: [ExpiryModel.dateText(it.expiryDate) + "到期",
                                      ExpiryModel.daysText(it) + " · 账上约 \(it.qtyLeft) \(it.unit)",
                                      it.awaitingUpload ? "上次的处理还没传上去，传完再处理" : ""],
                    id: "expiry.\(kind.rawValue).\(i)", action: { expiry.open(it) })
            }
        }
    }
}

/// 一行：缩略图、名称、两行小字、「处理」（已过期黑底，快过期描边）
private struct Row: View {
    let item: ExpiryItem
    let lines: [String]
    let id: String
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Thumb(initial: String(item.name.prefix(1)), ref: ImageKey(item.productId, item.imageVer), fill: Tokens.Palette.line.opacity(0.6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(lines.filter { !$0.isEmpty }, id: \.self) {
                        Text($0).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(id)
                if let action {
                    Button(action: action) {
                        Text("处理")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(item.expired ? Color.white : Tokens.Palette.ink)
                            .frame(minWidth: 96, minHeight: 64)
                            .background(item.expired ? Tokens.Palette.ink : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle())
                    // 本机对这批的「再提醒」还没传上去：传完（拉下新版本）才能再处理，见 `ExpiryItem.awaitingUpload`
                    .disabled(item.awaitingUpload)
                    .opacity(item.awaitingUpload ? 0.35 : 1)
                    .accessibilityIdentifier(id + ".handle")
                }
            }
            .padding(.vertical, 14)
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
        }
    }
}

/// 20 / 20b 处理面板：先问实际数，再选怎么处理；第一个选择突出，实际数为 0 时扔掉、退货置灰；「先不处理」关面板
private struct ExpiryPanel: View {
    @Bindable var expiry: ExpiryModel
    let item: ExpiryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.name)
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("expiry.panel.title")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { daysLine; Spacer(minLength: 0); qtyLine }
                VStack(alignment: .leading, spacing: 4) { daysLine; qtyLine }
            }
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { askText; Spacer(minLength: 0); stepper }
                VStack(alignment: .leading, spacing: 10) { askText; stepper }
            }
            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
            let top = expiry.emphasized(item)
            ForEach(expiry.choices(item), id: \.self) { c in
                ChoiceButton(icon: ExpiryModel.icon(c), title: expiry.title(c), detail: expiry.detail(c, item: item),
                             emphasized: c == top, enabled: c.enabled(actualQty: Int64(expiry.actualQty))) {
                    expiry.choose(c)
                }
                .accessibilityIdentifier("expiry.choice.\(c.rawValue)")
                .accessibilityValue(c == top ? "突出" : "")
            }
            if let f = expiry.failure {
                Text(f).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell).accessibilityIdentifier("expiry.failure")
            }
            PrimaryButton("先不处理", style: .ghost, size: .medium) { expiry.handling = nil }
                .accessibilityIdentifier("expiry.later")
        }
    }

    private var daysLine: some View {
        Text(ExpiryModel.panelDaysText(item)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            .accessibilityIdentifier("expiry.panel.days")
    }

    private var qtyLine: some View {
        Text("账上约 \(item.qtyLeft) \(item.unit)").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            .accessibilityIdentifier("expiry.panel.book")
    }

    private var askText: some View {
        Text("货架上这批\n实际还有几\(item.unit)")
            .font(TypeScale.body.weight(.bold))
            .foregroundStyle(Tokens.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stepper: some View {
        QuantityStepper(value: $expiry.actualQty, range: expiry.stepperRange(item))
            .accessibilityIdentifier("expiry.qty")
    }
}

/// 面板上的一个选择：图标 + 两行字。突出的黑底白字，其余描边；不能点的灰
private struct ChoiceButton: View {
    let icon: String
    let title: String
    let detail: String
    let emphasized: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        let fg: Color = !enabled ? PrimaryButton.disabledGhost : emphasized ? .white : Tokens.Palette.ink
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: icon).font(.system(size: 24, weight: .bold)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(TypeScale.title).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(TypeScale.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(emphasized && enabled ? Tokens.Palette.ink : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button)
                .strokeBorder(enabled ? Tokens.Palette.ink : PrimaryButton.disabledGhost, lineWidth: 2.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .disabled(!enabled)
    }
}
