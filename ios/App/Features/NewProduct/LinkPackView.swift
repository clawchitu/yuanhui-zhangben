import ShopCore
import SwiftUI

/// 05 整箱 / 整条：这个码是哪个商品的整箱（默认价签里那一样，「换一个」按名称找）、一整是箱 / 条 / 提 / 盒、
/// 一箱几个、整箱卖多少钱（不填就按单价 × 个数）。存好后交回调用方（卖出页把这一箱放进购物篮）。
struct LinkPackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: LinkPackModel
    @State private var picking = false
    let pendingCount: Int?
    let fixture: NewProductFixture
    let onDone: (PackConversion) -> Void

    init(db: LocalDB, barcode: String, mode: ShopMode, pendingCount: Int?, product: Product?,
         fixture: NewProductFixture = .none, onDone: @escaping (PackConversion) -> Void) {
        let m = LinkPackModel(db: db, barcode: barcode, mode: mode, product: product)
        #if DEBUG
        if let u = fixture.packUnit { m.unitName = u }
        for c in fixture.packQty ?? "" { if let d = c.wholeNumberValue { m.key(.digit(d)) } }
        if let p = fixture.packPrice {
            m.active = .price
            for c in p { if c == "." { m.key(.dot) } else if let d = c.wholeNumberValue { m.key(.digit(d)) } }
        }
        #endif
        _model = State(initialValue: m)
        self.pendingCount = pendingCount
        self.fixture = fixture
        self.onDone = onDone
    }

    private var unit: String { model.unitName }
    private var baseUnit: String { model.product?.baseUnit ?? "个" }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "整箱 / 整条", mode: model.mode, pendingCount: pendingCount, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("这个码是哪个商品的整\(unit)？")
                        .font(TypeScale.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("条码 \(model.barcode)").font(TypeScale.number(20)).foregroundStyle(Tokens.Palette.ink2)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    productCard
                    Text("这个码是一整").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    unitChips
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 两个输入框、换算说明、键盘、按钮钉在底部：输入框不被键盘压住
            VStack(alignment: .leading, spacing: 6) {
                fields
                if let h = model.problem {
                    hint(h, color: Tokens.Palette.sell).accessibilityIdentifier("linkPack.problem")
                } else if let h = model.conversionHint {
                    hint(h, color: Tokens.Palette.ink2).accessibilityIdentifier("linkPack.hint")
                }
                if model.problem == nil, let d = model.derivedPriceHint {
                    hint(d, color: Tokens.Palette.ink2).accessibilityIdentifier("linkPack.derived")
                }
            }
            .dynamicTypeSize(...DiscountPanel.labelCap)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            Keypad(showsDot: model.active == .price) { model.key($0) }
                .accessibilityIdentifier("linkPack.keypad")
                .padding(.horizontal, 20)
                .padding(.top, 6)
            PrimaryButton(model.mode == .stock ? "存好，接着进货" : "存好，接着卖", mode: model.mode) {
                if let conv = model.save() { onDone(conv) }
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier("linkPack.save")
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Tokens.Palette.paper)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.linkPack")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $picking) {
            ManualCodeView(db: model.db, mode: model.mode, pendingCount: pendingCount,
                           fixture: ManualFixture(tab: .name)) { code in
                model.choose(try? model.db.lookup(barcode: code))
                picking = false
            }
        }
    }

    private var productCard: some View {
        HStack(spacing: 14) {
            if let p = model.product {
                Thumb(initial: ProductNaming.isPlaceholder(p.name) ? nil : p.name.first.map(String.init), size: 64, fill: Tokens.Palette.line.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("linkPack.productName")
                    Text("单\(p.baseUnit)卖 ¥\(Money.yuanString(Int(p.priceFen.raw)))")
                        .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("还没选是哪个商品").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { picking = true } label: {
                Text(model.product == nil ? "选一个" : "换一个")
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("linkPack.choose")
        }
        .padding(14)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("linkPack.product")
    }

    private var unitChips: some View {
        HStack(spacing: 8) {
            ForEach(LinkPackModel.units, id: \.self) { u in
                let on = model.unitName == u
                Button { model.unitName = u } label: {
                    Text(u)
                        .font(.system(size: 26, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? .white : Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(on ? Tokens.Palette.ink : Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("linkPack.unit.\(u)")
            }
        }
    }

    @ViewBuilder private var fields: some View {
        let qty = box(label: "一\(unit)里有几\(baseUnit)", field: .qty, text: model.qtyText, prefix: nil)
            .accessibilityIdentifier("linkPack.qty")
        let price = box(label: "整\(unit)卖多少钱", field: .price, text: model.price.text, prefix: "¥",
                        placeholder: "可以不填")
            .accessibilityIdentifier("linkPack.price")
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) { qty; price }
            VStack(alignment: .leading, spacing: 10) { qty; price }
        }
    }

    private func box(label: String, field: LinkPackModel.Field, text: String, prefix: String?, placeholder: String = "")
        -> some View {
        let on = model.active == field
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .lineLimit(1).minimumScaleFactor(0.7)
            Button { model.active = field } label: {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let prefix { Text(prefix).font(TypeScale.number(24)) }
                    if text.isEmpty && !on {
                        Text(placeholder).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.mute)
                    } else {
                        Text(text).font(TypeScale.number(44)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    if on { Rectangle().fill(model.mode.color).frame(width: 2.5, height: 38) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 16)
                .frame(minWidth: 150, maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(on ? model.mode.color : Tokens.Palette.line, lineWidth: on ? 2.5 : 2))
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.card + 4).fill(on ? model.mode.tint : .clear).padding(-5))
                .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.isEmpty ? "\(label)，没填" : "\(label) \(text)")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    private func hint(_ s: String, color: Color) -> some View {
        Text(s).font(TypeScale.secondary.weight(.medium)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
