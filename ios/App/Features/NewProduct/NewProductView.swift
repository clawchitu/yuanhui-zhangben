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
    /// 量出来的高度，给名称框定行数用（PR #43 Fable 决定：一次只做一件事、按可用高度定行数）
    /// 平时：上部滚动区高度 + 自家数字键盘高度（和键压多矮无关，避免来回跳）
    @State private var nameRoom: CGFloat = 0
    /// 写名称时：上部滚动区高度（顶栏下沿到「写好了」上沿）
    @State private var editRoom: CGFloat = 0
    @State private var nameLabelHeight: CGFloat = 0
    @State private var noticeHeight: CGFloat = 0
    /// 名称整段不限行时要几行
    @State private var nameNaturalLines = 1
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
        // 卖价是 0：再问一句（PR #30 Fable 建议 2）
        .alert("卖价是 0 元，确定吗？", isPresented: Binding(get: { model.confirmZeroPrice },
                                                       set: { if !$0 { model.cancelZeroPrice() } })) {
            Button("确定，就卖 0 元") { model.step == .basic ? saveBasic(confirmedZero: true) : saveMore(confirmedZero: true) }
            Button("再改改", role: .cancel) { model.cancelZeroPrice() }
        } message: {
            Text("顾客扫到这一样会按 ¥0.00 收钱")
        }
        .task {
            model.applyLookup(await lookup.lookup(model.barcode))
            applyFixture()
        }
    }

    // MARK: 04a / 04c / 25e

    private var basic: some View {
        let fit = nameFit
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // 写名称时只留名称：标题、条码、横幅、整箱按钮先收起来（只是不显示）
                    if !nameFocused {
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
                    }
                    // 名称标签和卖价标签一样封顶（SE + 最大辅助字号下省出一行名称的高度，见 PR #43）
                    label(model.nameLabel)
                        .dynamicTypeSize(...DiscountPanel.labelCap)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameLabelHeight = $0 }
                        .accessibilityIdentifier("newProduct.nameLabel")
                    // 名称框多行：长名自动换行，首字头像与框顶对齐（真机 11/24：单行把「农夫山泉 饮用天然水 550…」截掉了）
                    HStack(alignment: .top, spacing: 12) {
                        Thumb(initial: initial, size: 64, fill: Tokens.Palette.line.opacity(0.6))
                            .overlay { if initial == nil { Text("?").font(.system(size: 34, weight: .bold)).foregroundStyle(Tokens.Palette.ink2) } }
                        nameBox(lines: nameFocused ? editLines : fit.lines)
                    }
                    // 名称末尾像条码：提示单独在名称框下面，名称一改就清；人点了才去掉（PR #31 Codex 1、Fable 建议 4）
                    if !nameFocused, let n = model.nameScanNotice {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(n).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("newProduct.nameNotice")
                            if model.canStripCode {
                                Button { model.stripScannedCode() } label: {
                                    Text("是条码，去掉这串数字").font(TypeScale.body.weight(.semibold)).underline()
                                        .foregroundStyle(Tokens.Palette.ink).frame(minHeight: Tokens.Size.minHitTarget)
                                }
                                .accessibilityIdentifier("newProduct.stripCode")
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
                        .onDisappear { noticeHeight = 0 }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, Self.scrollTopPad)
                .padding(.bottom, Self.scrollBottomPad)
                // 写名称时名称贴着顶栏，不跟着 bottom 锚点沉到下面
                .frame(maxWidth: .infinity, minHeight: nameFocused ? max(0, editRoom - 1) : 0, alignment: .topLeading)
            }
            // 写名称时内容不满一屏也能往下拖，拖一下收键盘
            .scrollBounceBehavior(nameFocused ? .always : .basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // 放不下时先露出最下面的名称框（标题往上滚），名称和卖价总在首屏
            .defaultScrollAnchor(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { h in
                if nameFocused {
                    if abs(editRoom - h) >= 1 { editRoom = h }
                } else {
                    let room = h + Keypad.height(key: fit.key, spacing: fit.spacing) + (fit.tight ? 0 : tightSavings)
                    if abs(nameRoom - room) >= 1 { nameRoom = room }
                }
            }
            .accessibilityIdentifier("newProduct.scroll")
            if nameFocused {
                // 写名称时：键盘上方一个大的「写好了」，和回车、扫码枪回车走同一条路
                PrimaryButton("写好了", mode: model.mode, size: .medium) { finishName() }
                    .dynamicTypeSize(...DiscountPanel.labelCap)
                    .accessibilityIdentifier("newProduct.nameDone")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Tokens.Palette.paper)
            } else {
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
                .padding(.top, fit.tight ? 2 : 6)
                Keypad(keyHeight: fit.key, spacing: fit.spacing) { model.priceKey($0) }
                    .accessibilityIdentifier("newProduct.keypad")
                    .padding(.horizontal, 20)
                    .padding(.top, fit.tight ? 2 : 6)
                basicButtons(tight: fit.tight)
            }
        }
    }

    static let scrollTopPad: CGFloat = 14, scrollBottomPad: CGFloat = 10
    /// 名称 28pt 粗体，不随辅助字号变（PR #43 Fable 决定：不放大也不缩小）
    static let nameFontSize: CGFloat = 28
    static let nameLineHeight = UIFont.systemFont(ofSize: nameFontSize, weight: .bold).lineHeight
    /// 名称框外框高：n 行字 + 上下 12pt 留白，至少和首字头像一样高
    static func nameBoxHeight(_ lines: Int) -> CGFloat { max(64, CGFloat(lines) * nameLineHeight + 24) }
    static let keyMin: CGFloat = 44, keySpacingTight: CGFloat = 4

    /// `tight`：数字键压矮了，底部同时收紧（上下留白各少 4pt、主按钮 72→64pt、两个按钮间距 10→6）
    struct NameFit: Equatable { var lines: Int; var key: CGFloat; var spacing: CGFloat; var tight: Bool = false }

    /// 收紧底部省下的高度（不含数字键本身），和 `basic`、`basicButtons` 里的 tight 分支一一对应
    static func tightSavings(twoButtons: Bool) -> CGFloat {
        4 + 4 + 4 + (PrimaryButton.Size.regular.height - PrimaryButton.Size.medium.height) + (twoButtons ? 4 : 0)
    }
    private var tightSavings: CGFloat { Self.tightSavings(twoButtons: model.offersQuickSave && model.offersSecondStep) }

    /// 平时名称框的行数和数字键高：按可用高度取 3→2→1 行；放不下 2 行时先把键压矮（最低 44），压到底才降到 1 行。
    /// 「名称标签 + 整个名称框（+ 条码提示）」必须整块落在滚动区里，开头不被滚出去
    /// `room`：按收紧后的底部算，滚动区 + 数字键能用的总高
    static func fitName(room: CGFloat, labelHeight: CGFloat, noticeHeight: CGFloat, naturalLines: Int,
                        tightSavings: CGFloat) -> NameFit {
        let full = NameFit(lines: min(nameDisplayLines, max(1, naturalLines)), key: Tokens.Size.key, spacing: 8)
        guard room > 0 else { return full }
        func need(_ n: Int) -> CGFloat {
            labelHeight + 8 + nameBoxHeight(n) + (noticeHeight > 0 ? 8 + noticeHeight : 0) + scrollBottomPad + 2
        }
        let fullKeypad = Keypad.height(key: Tokens.Size.key, spacing: 8)
        // 名称本来就只要 1 行时下限就是 1 行；否则先在 2 行以上找，不压键
        let floor = min(full.lines, 2)
        for n in stride(from: full.lines, through: floor, by: -1) where room - tightSavings - fullKeypad >= need(n) {
            return NameFit(lines: n, key: Tokens.Size.key, spacing: 8)
        }
        for n in stride(from: floor, through: 1, by: -1) {
            let key = ((room - need(n)) - 3 * keySpacingTight) / 4
            if key >= keyMin {
                return NameFit(lines: n, key: min(Tokens.Size.key, key.rounded(.down)), spacing: keySpacingTight, tight: true)
            }
        }
        return NameFit(lines: 1, key: keyMin, spacing: keySpacingTight, tight: true)
    }

    private var nameFit: NameFit {
        Self.fitName(room: nameRoom, labelHeight: nameLabelHeight, noticeHeight: noticeHeight, naturalLines: nameNaturalLines,
                     tightSavings: tightSavings)
    }

    /// 写名称时的行数：最多 4 行（超出框内滚动），高度不够按可用高度减行，最少 2 整行
    static func fitEditLines(room: CGFloat, labelHeight: CGFloat) -> Int {
        guard room > 0 else { return nameEditLines }
        let fixed = scrollTopPad + labelHeight + 8 + 24 + scrollBottomPad + 2
        let n = Int(((room - fixed) / nameLineHeight).rounded(.down))
        return min(nameEditLines, max(2, n))
    }

    private var editLines: Int { Self.fitEditLines(room: editRoom, labelHeight: nameLabelHeight) }

    /// 「写好了」、键盘回车、扫码枪回车三条路一样：去掉换行、收键盘、做名称检查，回到平时布局
    private func finishName() {
        if model.name.contains(where: \.isNewline) { model.name = model.name.filter { !$0.isNewline } }
        nameFocused = false
        model.submitName()
    }

    /// 名称框行数上限：显示时最多 3 行（再长才省略），编辑时随内容增高到 4 行，之后框内滚动；小屏按可用高度再减
    static let nameDisplayLines = 3
    static let nameEditLines = 4

    /// 名称框：竖向 TextField 负责编辑；没在编辑时字设成透明，上面盖一层最多 3 行、超出才省略的 Text，
    /// 两者同字号同宽、行数上限相同，框高一致。TextField 一直在层级里，点框任何地方都进编辑，焦点不丢。
    private func nameBox(lines: Int) -> some View {
        let font = Font.system(size: Self.nameFontSize, weight: .bold)
        return TextField("", text: $model.name, prompt: Text("看包装写一下").foregroundStyle(Tokens.Palette.mute), axis: .vertical)
            .font(font)
            .lineLimit(1...lines)
            .foregroundStyle(nameFocused || model.name.isEmpty ? Tokens.Palette.ink : Color.clear)
            .tint(model.mode.color)
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit { finishName() }
            // 竖向 TextField 回车会插入换行：名称里不留换行，回车（含扫码枪的回车）照旧当「写好了」
            .onChange(of: model.name) { _, v in
                guard v.contains(where: \.isNewline) else { return }
                finishName()
            }
            .autocorrectionDisabled()
            // 量整段名称不限行要几行（同字号同宽），短名不用为了「放 2 行」去压矮数字键
            .background(alignment: .topLeading) {
                Text(model.name.isEmpty ? " " : model.name)
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: Int.self) { max(1, Int(($0.size.height / Self.nameLineHeight).rounded())) } action: {
                        nameNaturalLines = $0
                    }
            }
            .overlay(alignment: .topLeading) {
                if !nameFocused && !model.name.isEmpty {
                    Text(model.name)
                        .font(font)
                        .foregroundStyle(Tokens.Palette.ink)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { nameFocused = true }
            .accessibilityIdentifier("newProduct.name")
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
                Text(model.price.text).font(TypeScale.number(44)).lineLimit(1).minimumScaleFactor(0.5)
                Rectangle().fill(model.mode.color).frame(width: 2.5, height: 40).opacity(nameFocused ? 0 : 1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 66)
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

    private func basicButtons(tight: Bool) -> some View {
        VStack(spacing: tight ? 6 : 10) {
            if model.offersQuickSave {
                PrimaryButton(model.mode == .stock ? "存好，接着进货" : "存好，接着卖", mode: model.mode, size: tight ? .medium : .regular) { saveBasic() }
                    .disabled(!model.canSaveBasic)
                    .accessibilityIdentifier("newProduct.save")
            }
            if model.offersSecondStep {
                PrimaryButton("再填进价和库存", mode: model.mode, style: model.offersQuickSave ? .ghost : .filled,
                              size: model.offersQuickSave ? .small : (tight ? .medium : .regular)) {
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
        .padding(.top, tight ? 6 : 10)
        .padding(.bottom, 8)
        .background(Tokens.Palette.paper)
    }

    private func saveBasic(confirmedZero: Bool = false) {
        if let conv = model.saveBasic(confirmedZero: confirmedZero) { onDone(.registered(conv, quick: model.quick)) }
    }

    private func saveMore(confirmedZero: Bool = false) {
        moreFocus = nil
        if let conv = model.saveMore(confirmedZero: confirmedZero) { onDone(.registered(conv, quick: false)) }
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
            PrimaryButton("存好", systemImage: "checkmark", mode: model.mode) { saveMore() }
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
