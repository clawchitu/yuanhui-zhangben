import ShopCore
import SwiftUI

/// 抹零 / 改总价面板（18），和它的二次确认（28）。卖出页用 `.sheet` 弹出：
/// 键盘阶段占满（18），要再问一次时收成半屏（28），露出后面的卖出页。
///
/// 全是自家键盘，不弹系统键盘；面板里没有文本框，扫码枪的按键不会被它截走（关面板时卖出页会抢回，§14 S14-4）。
struct DiscountPanel: View {
    @State private var model: DiscountModel
    var mode: ShopMode = .sell
    let onDone: (DiscountModel.Outcome?) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    init(basket: Basket, mode: ShopMode = .sell, fixtureKeys: String? = nil, fixtureSubmit: Bool = false,
         onDone: @escaping (DiscountModel.Outcome?) -> Void) {
        let m = DiscountModel(basket: basket)
        #if DEBUG
        // 截图夹具：开面板后按这几个键，要不要再按「就收这么多」（只为出 28，定下来的结果不交出去）
        if let keys = fixtureKeys {
            for ch in keys { m.key(ch == "." ? .dot : .digit(Int(String(ch)) ?? 0)) }
            if fixtureSubmit { _ = m.submit() }
        }
        #endif
        _model = State(initialValue: m)
        self.mode = mode
        self.onDone = onDone
    }

    var body: some View {
        Group {
            switch model.stage {
            case .input: inputStage
            case .confirm(let p, let over): confirmStage(p, over: over)
            }
        }
        .background(Tokens.Palette.card.ignoresSafeArea())
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Tokens.Radius.sheet)
        .animation(.easeOut(duration: 0.2), value: model.stage)
    }

    /// 18 占满；28 半屏（辅助字号下文字放不下，也占满）
    private var detents: Set<PresentationDetent> {
        if case .confirm = model.stage, !typeSize.isAccessibilitySize { return [.medium] }
        return [.large]
    }

    // MARK: 18

    /// 18 上的标签和说明随系统字号放大到这一档为止：再大就把键盘挤出首屏（金额数字本来就是固定大字）
    static let labelCap = DynamicTypeSize.xxLarge

    private var inputStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("抹零 / 改总价")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.top, 22)
                HStack(alignment: .firstTextBaseline) {
                    Text("原价").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                        .dynamicTypeSize(...Self.labelCap)
                    Spacer(minLength: 8)
                    PriceText(cents: Int(model.listFen), size: 34)
                        .accessibilityIdentifier("discount.list")
                }
                quickRow
                Text("实收多少").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2).padding(.top, 4)
                    .dynamicTypeSize(...Self.labelCap)
                inputField
                summaryRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        // 键盘钉在底部、主按钮上面：最大辅助字号下上面的说明区滚动，键盘始终在首屏（Fable 审核建议 2）
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Keypad { model.key($0) }
                    .accessibilityIdentifier("discount.keypad")
                    .padding(.bottom, 2)
                PrimaryButton("就收这么多", mode: mode) {
                    if let r = model.submit() { onDone(r) }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("discount.submit")
                Text("比原价少太多（不到七折）或者多收了，会再问一次")
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // 钉在底部的说明不跟着辅助字号无限放大：最大辅助字号下它曾占掉半屏，把键盘挤到要滚动才看得见
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Tokens.Palette.card)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.discount.pageId)
    }

    /// 「抹到 ¥53」「抹到 ¥50」「不抹了」。字号固定，放不下时缩字（金额长）
    private var quickRow: some View {
        HStack(spacing: 10) {
            quickButton("抹到 ¥\(model.roundYuanFen / 100)", fen: model.roundYuanFen, id: "discount.roundYuan")
            quickButton("抹到 ¥\(model.roundTenFen / 100)", fen: model.roundTenFen, id: "discount.roundTen")
            QuickKey(title: "不抹了", selected: false) { onDone(.restore) }
                .accessibilityIdentifier("discount.restore")
        }
    }

    private func quickButton(_ title: String, fen: Int64, id: String) -> some View {
        QuickKey(title: title, selected: model.isSelected(fen)) { model.round(to: fen) }
            .disabled(!model.canRound(to: fen))
            .accessibilityIdentifier(id)
    }

    private var inputField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("¥").font(TypeScale.number(28))
            Text(model.text).font(TypeScale.number(48))
            Rectangle().fill(mode.color).frame(width: 2.5, height: 44).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 18)
        .frame(height: 84)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(mode.color, lineWidth: 2.5))
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.card + 4).fill(mode.tint).padding(-5))
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.text.isEmpty ? "实收还没输" : "实收 \(model.text) 元")
        .accessibilityIdentifier("discount.input")
    }

    /// 「优惠 ¥0.50」；多收时「多收 ¥x」；超上限时换成红字的上限
    @ViewBuilder private var summaryRow: some View {
        if let msg = model.limitMessage {
            Text(msg)
                .font(TypeScale.body.weight(.semibold))
                .foregroundStyle(Tokens.Palette.sell)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(...Self.labelCap)
                .accessibilityIdentifier("discount.limit")
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text((model.discountFen ?? 0) < 0 ? "多收" : "优惠")
                    .font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                    .dynamicTypeSize(...Self.labelCap)
                Spacer(minLength: 8)
                if let d = model.discountFen {
                    PriceText(cents: Int(d.magnitude), size: 30)
                } else {
                    Text("—").font(TypeScale.number(30)).foregroundStyle(Tokens.Palette.mute)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("discount.amount")
        }
    }

    // MARK: 28

    private func confirmStage(_ p: Int64, over: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.confirmTitle(paidFen: p, over: over))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("discount.confirm.title")
                Text(model.confirmDetail(paidFen: p, over: over))
                    .font(TypeScale.body)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("discount.confirm.detail")
                PrimaryButton("输错了，重填", mode: mode) { model.refill() }
                    .accessibilityIdentifier("discount.refill")
                    .padding(.top, 6)
                PrimaryButton("没错，就收 \(DiscountModel.yuan(p))", mode: mode, style: .ghost) {
                    if let r = model.confirm() { onDone(r) }
                }
                .accessibilityIdentifier("discount.confirm")
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.discountConfirm")
    }
}

/// 18 上面一排三个快捷键：描边，选中时价签黄底。字号固定 24pt 粗体，金额长放不下时缩字
private struct QuickKey: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let color = isEnabled ? Tokens.Palette.ink : PrimaryButton.disabledGhost
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(selected ? Tokens.Palette.tag : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(color, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
