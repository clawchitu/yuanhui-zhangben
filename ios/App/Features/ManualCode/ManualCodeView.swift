import ShopCore
import SwiftUI

/// 手输条码（15）/ 按名称找（15b）。从卖出页的「手输条码」推进来（进货、盘点以后同样用它，`mode` 决定颜色）。
/// 选中一个按「就是它，加进去」→ `onPick(条码)`，由调用方关页面、把码交给扫码层。
struct ManualCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ManualCodeModel
    var mode: ShopMode = .sell
    var pendingCount: Int?
    /// nil = 直接塞路由进来的（没有购物篮可加）：选了就关页面
    let onPick: ((String) -> Void)?
    @FocusState private var nameFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(db: LocalDB, mode: ShopMode = .sell, pendingCount: Int? = nil, fixture: ManualFixture = .none,
         onPick: ((String) -> Void)? = nil) {
        let m = ManualCodeModel(db: db)
        #if DEBUG
        if let t = fixture.tab { m.tab = t }
        if let i = fixture.input { m.type(i) }
        if let q = fixture.query { m.query = q }
        if let n = fixture.selectIndex {
            let list = m.tab == .code ? m.candidates.map(\.conversion) : m.nameResults
            if list.indices.contains(n) { m.select(list[n]) }
        }
        #endif
        _model = State(initialValue: m)
        self.mode = mode
        self.pendingCount = pendingCount
        self.onPick = onPick
    }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: model.tab == .code ? "手输条码" : "按名称找", mode: mode, pendingCount: pendingCount,
                    onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    tabs
                    if model.tab == .code { codeSection } else { nameSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.never)
            // 输条码时键盘钉在底部、主按钮上面：候选多或字号大时上面滚动，键盘始终在首屏（Fable 审核建议 2）
            if model.tab == .code {
                Keypad(showsDot: false) { model.key($0) }
                    .accessibilityIdentifier("manual.keypad")
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(Tokens.Palette.paper)
            }
            bottom
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        // 输条码页上接硬件键盘 / 扫码枪：按键进输入框（不是进购物篮）；按名称找时按键归系统文本框
        .background(
            HIDKeyCapture(isActive: model.tab == .code) { key, _ in
                if let code = model.hardwareKey(key) { deliver(code) }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.manualCode.pageId)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func deliver(_ code: String) {
        if let onPick { onPick(code) } else { dismiss() }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(ManualCodeModel.Tab.allCases, id: \.self) { t in
                let on = model.tab == t
                Button {
                    model.tab = t
                    nameFocused = t == .name
                } label: {
                    Text(t == .code ? "输条码" : "按名称找")
                        .font(.system(size: 22, weight: on ? .bold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(on ? Tokens.Palette.ink : Tokens.Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(on ? Tokens.Palette.card : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("manual.tab.\(t.rawValue)")
            }
        }
        .padding(4)
        .background(Tokens.Palette.line.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: 15 输条码

    @ViewBuilder private var codeSection: some View {
        field {
            HStack(spacing: 2) {
                Text(model.input).font(TypeScale.number(44)).lineLimit(1).minimumScaleFactor(0.4)
                caret
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.input.isEmpty ? "条码还没输" : model.input)
        .accessibilityIdentifier("manual.input")
        Text(model.codeHint)
            .font(TypeScale.secondary)
            .foregroundStyle(model.hint == nil ? Tokens.Palette.ink2 : Tokens.Palette.sell)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DiscountPanel.labelCap)
            .accessibilityIdentifier("manual.hint")
        ForEach(model.candidates, id: \.self) { c in
            row(c.conversion, code: c.representativeBarcode, id: "manual.row.\(c.representativeBarcode)")
        }
    }

    // MARK: 15b 按名称找

    @ViewBuilder private var nameSection: some View {
        field {
            TextField("", text: $model.query, prompt: Text("商品名里的几个字").foregroundStyle(Tokens.Palette.mute))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Tokens.Palette.ink)
                .tint(mode.color)
                .focused($nameFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("manual.query")
        }
        Text("写几个字就行，手写也可以")
            .font(TypeScale.secondary)
            .foregroundStyle(Tokens.Palette.ink2)
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, model.nameResults.isEmpty {
            Text("没找到名字里有「\(model.query)」的商品")
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.nameResults, id: \.self) { c in
            row(c, code: nil, id: "manual.name.\(c.barcode.barcode)")
        }
    }

    // MARK: 共用

    private func field<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 18)
            .frame(minHeight: 72)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(mode.color, lineWidth: 2.5))
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.card + 4).fill(mode.tint).padding(-5))
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
    }

    private var caret: some View {
        Rectangle().fill(mode.color).frame(width: 2.5, height: 40)
    }

    /// 一个候选：缩略图（首字）、名称（整件码写明「箱（24 罐）」）、尾号或「选中了」、卖价。不带库存
    private func row(_ c: PackConversion, code: String?, id: String) -> some View {
        let on = model.isSelected(c)
        let name = c.packQty > 1 ? "\(c.product.name) · \(c.unitLabel)" : c.product.name
        return Button { model.select(c) } label: {
            HStack(spacing: 14) {
                Thumb(initial: ProductNaming.isPlaceholder(c.product.name) ? nil : c.product.name.first.map(String.init),
                      ref: Thumb.ref(c.product), size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(TypeScale.body.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : nil)
                        .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.6 : 1)
                    if on {
                        Text("选中了").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    } else if let code {
                        Text("…" + code.suffix(4)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    }
                }
                // 辅助字号下候选行收成一行名称（放不下缩字）、字号封顶，让键盘留在首屏
                .dynamicTypeSize(...DiscountPanel.labelCap)
                Spacer(minLength: 8)
                PriceText(cents: Int((try? c.unitPrice().raw) ?? 0), size: 30)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(on ? Tokens.Palette.tag : Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(on ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: on ? 2.5 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// 底部主按钮：没选中时灰的「先点上面选一个」，选中了是「就是它，加进去」
    private var bottom: some View {
        PrimaryButton(model.canPick ? "就是它，加进去" : "先点上面选一个", systemImage: model.canPick ? "checkmark" : nil, mode: mode) {
            if let code = model.pick() { deliver(code) }
        }
        .disabled(!model.canPick)
        .accessibilityIdentifier("manual.pick")
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Tokens.Palette.paper)
    }
}

/// 手输页的测试夹具（截图、UI 测试用；只在 Debug 认）
struct ManualFixture: Equatable, Sendable {
    var tab: ManualCodeModel.Tab?
    var input: String?
    var query: String?
    var selectIndex: Int?
    static let none = ManualFixture()
}
