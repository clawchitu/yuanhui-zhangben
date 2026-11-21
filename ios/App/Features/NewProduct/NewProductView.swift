import ShopCore
import SwiftUI

/// 登记 / 整件码做完交给调用方（卖出页把它放进购物篮）
enum RegistrationOutcome: Equatable {
    /// 登记了新商品；`quick` = 收银员临时登记（04c）
    case registered(PackConversion, quick: Bool)
    /// 把这个码挂成了已有商品的整箱 / 整条（05）
    case linked(PackConversion)

    var conversion: PackConversion {
        switch self {
        case .registered(let c, _), .linked(let c): c
        }
    }
}

/// 新商品登记：04a（家用第一步）→ 04b（第二步：进价、库存、保质期）；收银员只有 04c；没网时 25e。
/// 04a 的「这是整箱、整条的码」推到 05（`LinkPackView`）。从卖出进来两步都是朱红，从进货进来都是靛青。
struct NewProductView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: NewProductModel
    @State private var showPack = false
    @FocusState private var nameFocused: Bool
    @FocusState private var moreFocus: MoreField?
    @Environment(\.dynamicTypeSize) private var typeSize
    let lookup: any ProductNameLookup
    let pendingCount: Int?
    /// 05「换一个」前默认选的商品（卖出页：价签里那一样）
    let suggestedProduct: Product?
    let fixture: NewProductFixture
    let onDone: (RegistrationOutcome) -> Void

    enum MoreField: Hashable { case cost, qty, year, month, day }

    init(db: LocalDB, barcode: String, mode: ShopMode, quick: Bool, canLinkPack: Bool, lookup: any ProductNameLookup,
         pendingCount: Int?, suggestedProduct: Product? = nil, fixture: NewProductFixture = .none,
         onDone: @escaping (RegistrationOutcome) -> Void) {
        _model = State(initialValue: NewProductModel(db: db, barcode: barcode, mode: mode, quick: quick, canLinkPack: canLinkPack))
        self.lookup = lookup
        self.pendingCount = pendingCount
        self.suggestedProduct = suggestedProduct
        self.fixture = fixture
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: model.title, mode: model.mode, pendingCount: model.lookup == .offline ? nil : pendingCount,
                    offline: model.lookup == .offline, onBack: { if !model.back() { dismiss() } })
            if model.step == .basic { basic } else { more }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.step == .basic ? "page.newProduct" : "page.newProduct2")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showPack) {
            LinkPackView(db: model.db, barcode: model.barcode, mode: model.mode, pendingCount: pendingCount,
                         product: suggestedProduct, fixture: fixture) { conv in
                onDone(.linked(conv))
            }
        }
        .task {
            model.applyLookup(await lookup.lookup(model.barcode))
            applyFixture()
        }
    }

    // MARK: 04a / 04c / 25e

    private var basic: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.heading)
                        .font(TypeScale.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    codeLine
                    if model.lookup == .offline {
                        Banner(kind: .soft, text: "没网，查不到名称和图，先自己写", systemImage: "wifi.slash")
                            .accessibilityIdentifier("newProduct.offline")
                    }
                    if model.canLinkPack && model.mode != .neutral {
                        packButton
                    }
                    label(model.nameLabel)
                    HStack(spacing: 12) {
                        Thumb(initial: initial, size: 64, fill: Tokens.Palette.line.opacity(0.6))
                            .overlay { if initial == nil { Text("?").font(.system(size: 34, weight: .bold)).foregroundStyle(Tokens.Palette.ink2) } }
                        TextField("", text: $model.name, prompt: Text("看包装写一下").foregroundStyle(Tokens.Palette.mute))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Tokens.Palette.ink)
                            .tint(model.mode.color)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(minHeight: 64)
                            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
                            .accessibilityIdentifier("newProduct.name")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // 卖价框、键盘、按钮钉在底部：任何字号下卖价框都在首屏、不被键盘压住
            VStack(alignment: .leading, spacing: 6) {
                label(model.priceLabel)
                priceField
                if let m = model.priceMessage ?? model.error {
                    Text(m).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("newProduct.error")
                }
            }
            .dynamicTypeSize(...DiscountPanel.labelCap)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            // 写名称时系统键盘在下面，自家键盘先收起来；点卖价框再出来
            if !nameFocused {
                Keypad { model.priceKey($0) }
                    .accessibilityIdentifier("newProduct.keypad")
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
            basicButtons
        }
    }

    private var initial: String? {
        let n = model.name.trimmingCharacters(in: .whitespaces)
        return n.first.map(String.init)
    }

    private var codeLine: some View {
        HStack(spacing: 18) {
            Text("条码 \(model.barcode)").font(TypeScale.number(22))
            if model.quick, model.lookup == .notFound { Text("没查到名称").font(TypeScale.secondary) }
        }
        .foregroundStyle(Tokens.Palette.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityIdentifier("newProduct.code")
    }

    private var packButton: some View {
        Button { nameFocused = false; showPack = true } label: {
            HStack {
                Text("这是整箱、整条的码").font(TypeScale.body.weight(.bold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold))
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("newProduct.pack")
    }

    private var priceField: some View {
        Button { nameFocused = false } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("¥").font(TypeScale.number(28))
                Text(model.price.text).font(TypeScale.number(48)).lineLimit(1).minimumScaleFactor(0.5)
                Rectangle().fill(model.mode.color).frame(width: 2.5, height: 40).opacity(nameFocused ? 0 : 1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(model.mode.color, lineWidth: 2.5))
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.card + 4).fill(model.mode.tint).padding(-5))
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.price.isEmpty ? "卖价还没填" : "卖价 \(model.price.text) 元")
        .accessibilityIdentifier("newProduct.price")
    }

    private var basicButtons: some View {
        VStack(spacing: 10) {
            if model.offersQuickSave {
                PrimaryButton(model.mode == .stock ? "存好，接着进货" : "存好，接着卖", mode: model.mode) { saveBasic() }
                    .disabled(!model.canSaveBasic)
                    .accessibilityIdentifier("newProduct.save")
            }
            if model.offersSecondStep {
                PrimaryButton("再填进价和库存", mode: model.mode, style: model.offersQuickSave ? .ghost : .filled,
                              size: model.offersQuickSave ? .small : .regular) {
                    nameFocused = false
                    model.goMore()
                }
                .disabled(!model.canSaveBasic)
                .accessibilityIdentifier("newProduct.more")
            }
            if model.quick {
                Text("会标成「待确认」，回头让家里人补进价")
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(...DiscountPanel.labelCap)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Tokens.Palette.paper)
    }

    private func saveBasic() {
        if let conv = model.saveBasic() { onDone(.registered(conv, quick: model.quick)) }
    }

    // MARK: 04b

    private var more: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryCard
                    costAndQty
                    if model.missingCostWarning {
                        Banner(kind: .alert, text: "没填进价，赚多少先算不出来", systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("newProduct.costWarning")
                    }
                    Rectangle().fill(Tokens.Palette.line).frame(height: 1).padding(.vertical, 4)
                    Toggle(isOn: $model.trackExpiry) {
                        Text("这个要管保质期").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                    }
                    .tint(Tokens.Palette.ink)
                    .accessibilityIdentifier("newProduct.trackExpiry")
                    if model.showsExpiryFields { expiryFields }
                    if let e = model.error {
                        Text(e).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("newProduct.error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // 数字键盘没有回车：键盘上方放「好了」收起键盘
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("好了") { moreFocus = nil }
                        .font(TypeScale.body.weight(.bold))
                        .accessibilityIdentifier("newProduct.keyboardDone")
                }
            }
            PrimaryButton("存好", systemImage: "checkmark", mode: model.mode) {
                moreFocus = nil
                if let conv = model.saveMore() { onDone(.registered(conv, quick: false)) }
            }
            .disabled(!model.canSaveBasic)
            .accessibilityIdentifier("newProduct.saveMore")
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Tokens.Palette.paper)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            Thumb(initial: initial, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name.trimmingCharacters(in: .whitespaces).isEmpty ? "（没写名称）" : model.name)
                    .font(TypeScale.body.weight(.bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Text("卖 ¥\(Money.yuanString(Int(model.priceFen ?? 0)))")
                    Text("条码 …\(model.barcode.suffix(4))")
                }
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("newProduct.summary")
    }

    @ViewBuilder private var costAndQty: some View {
        let unit = model.baseUnit
        let costBox = VStack(alignment: .leading, spacing: 6) {
            label("进价（每\(unit)）")
            numberField("不知道先不填", text: Binding(get: { model.cost.text }, set: { model.cost = YuanInput($0) }),
                        field: .cost, keyboard: .decimalPad, prefix: "¥")
                .accessibilityIdentifier("newProduct.cost")
        }
        let qtyBox = VStack(alignment: .leading, spacing: 6) {
            label("货架上现在有几\(unit)")
            numberField("", text: $model.qtyText, field: .qty, keyboard: .numberPad)
                .accessibilityIdentifier("newProduct.qty")
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) { costBox; qtyBox }
        } else {
            HStack(alignment: .bottom, spacing: 14) { costBox; qtyBox }
        }
    }

    @ViewBuilder private var expiryFields: some View {
        HStack(alignment: .firstTextBaseline) {
            label("这批哪天到期")
            Spacer(minLength: 8)
            Button(model.expiryUnknown ? "知道，填上" : "不知道，先不填") {
                model.expiryUnknown.toggle()
                if model.expiryUnknown { model.year = ""; model.month = ""; model.day = ""; moreFocus = nil }
            }
            .font(TypeScale.secondary.weight(.bold))
            .underline()
            .foregroundStyle(Tokens.Palette.ink)
            .frame(minHeight: 44)
            .accessibilityIdentifier("newProduct.expiryUnknown")
        }
        if model.expiryUnknown {
            Text("这批的到期日先不填，以后进货时再填")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("newProduct.expiryUnknownNote")
        } else {
            HStack(spacing: 10) {
                dateBox($model.year, "年", .year, placeholder: "2027").frame(maxWidth: .infinity)
                dateBox($model.month, "月", .month, placeholder: "05").frame(maxWidth: .infinity)
                dateBox($model.day, "日", .day, placeholder: "20").frame(maxWidth: .infinity)
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack {
                label("提前几天提醒")
                Spacer(minLength: 8)
                QuantityStepper(value: $model.warnDays, range: 0...Int(Limits.maxExpiryWarnDays), compact: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                label("提前几天提醒")
                QuantityStepper(value: $model.warnDays, range: 0...Int(Limits.maxExpiryWarnDays), compact: true)
            }
        }
    }

    private func dateBox(_ text: Binding<String>, _ unit: String, _ field: MoreField, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Tokens.Palette.mute))
                .font(TypeScale.number(36))
                .keyboardType(.numberPad)
                .focused($moreFocus, equals: field)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .onChange(of: text.wrappedValue) { _, v in advance(from: field, v) }
                .accessibilityIdentifier("newProduct.\(field)")
            Text(unit).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { moreFocus = field }
    }

    /// 年月日填满自动跳到下一格
    private func advance(from field: MoreField, _ v: String) {
        switch field {
        case .year where v.count == 4: moreFocus = .month
        case .month where v.count == 2: moreFocus = .day
        default: break
        }
    }

    private func numberField(_ prompt: String, text: Binding<String>, field: MoreField, keyboard: UIKeyboardType,
                             prefix: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if let prefix, !text.wrappedValue.isEmpty { Text(prefix).font(TypeScale.number(24)) }
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Tokens.Palette.mute).font(TypeScale.secondary))
                .font(TypeScale.number(40))
                .keyboardType(keyboard)
                .focused($moreFocus, equals: field)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
            .strokeBorder(moreFocus == field ? model.mode.color : Tokens.Palette.line, lineWidth: moreFocus == field ? 2.5 : 2))
        .contentShape(Rectangle())
        .onTapGesture { moreFocus = field }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 测试夹具（只在 Debug 有内容）：预先填好各格，必要时直接跳到第二步 / 05
    private func applyFixture() {
        #if DEBUG
        if let n = fixture.name { model.name = n }
        if let p = fixture.price { model.price = YuanInput(p) }
        if fixture.step2 {
            model.goMore()
            if let c = fixture.cost { model.cost = YuanInput(c) }
            if let q = fixture.qty { model.qtyText = q }
            if let e = fixture.expiry {
                model.trackExpiry = true
                if e == "unknown" { model.expiryUnknown = true }
                let parts = e.split(separator: "-").map(String.init)
                if parts.count == 3 { model.year = parts[0]; model.month = parts[1]; model.day = parts[2] }
            }
            if let w = fixture.warnDays { model.warnDays = w }
        }
        if fixture.pack { showPack = true }
        #endif
    }
}

/// 登记页 / 05 的测试夹具（截图、UI 测试用；只在 Debug 认）
struct NewProductFixture: Equatable, Sendable {
    var name: String?
    var price: String?
    var step2 = false
    var cost: String?
    var qty: String?
    /// "2027-05-20"、"on"（只打开开关）、"unknown"（「不知道，先不填」）
    var expiry: String?
    var warnDays: Int?
    /// 直接推到 05
    var pack = false
    var packUnit: String?
    var packQty: String?
    var packPrice: String?
    var mode: ShopMode?
    static let none = NewProductFixture()
}
