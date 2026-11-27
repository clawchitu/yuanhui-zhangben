import ShopCore
import SwiftUI

/// 11 商品（仅家用）：搜索框、筛选标签（全部 / 快过期 / 待确认 / 快没货 / 没进价，带数）、每个商品三行 + 卖价 + 「改」。
/// 「改」进 22；待确认的进 22b。数全部来自本机商品表，离线也能看。
struct ProductsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var list: ProductsModel?
    @State private var editing: Target?
    @FocusState private var searchFocused: Bool

    struct Target: Identifiable, Hashable {
        let id: UUID
        let review: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.products.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let list {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        search(list)
                        chips(list)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        let rows = list.shown
                        if list.loaded && rows.isEmpty {
                            Text(list.query.isEmpty ? "这一栏没有商品" : "没找到「\(list.query)」")
                                .font(TypeScale.body)
                                .foregroundStyle(Tokens.Palette.ink2)
                                .padding(.top, 30)
                                .accessibilityIdentifier("products.empty")
                        }
                        ForEach(rows) { it in
                            ProductRow(item: it) { editing = Target(id: it.id, review: it.product.needsReview && !it.product.archived) }
                            Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await list.reload(today: today) }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationDestination(item: $editing) { t in
            if t.review {
                ReviewProductLoader(id: t.id)
            } else {
                EditProductLoader(id: t.id)
            }
        }
        .onAppear {
            if list == nil { list = ProductsModel(db: model.db) }
            applyFixture()
            Task { await list?.reload(today: today) }
        }
        // 同步拉下来新数（别的手机改了价、补全了）就重读
        .onChange(of: model.sync?.status?.lastSyncAt) { _, _ in Task { await list?.reload(today: today) } }
        .onChange(of: editing) { _, t in if t == nil { Task { await list?.reload(today: today) } } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.products.pageId)
    }

    private var today: CalendarDate { LocalDB.shanghaiDay(model.now) }

    private func search(_ list: ProductsModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Tokens.Palette.ink2)
                .accessibilityHidden(true)
            TextField("", text: Bindable(list).query,
                      prompt: Text("搜名称，或者扫条码").foregroundStyle(Tokens.Palette.ink2.opacity(0.7)))
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("products.search")
            if !list.query.isEmpty {
                Button { list.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundStyle(Tokens.Palette.mute)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("清空")
                .accessibilityIdentifier("products.search.clear")
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2.5))
        .padding(.top, 8)
    }

    private func chips(_ list: ProductsModel) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(ProductsModel.chips, id: \.0) { f, title in
                let on = list.filter == f
                Button { list.filter = f } label: {
                    Text("\(title) \(list.counts[f])")
                        .font(TypeScale.body.weight(on ? .bold : .regular))
                        .foregroundStyle(on ? Color.white : Tokens.Palette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .background(on ? Tokens.Palette.ink : Tokens.Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("products.chip.\(f.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func applyFixture() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let f = UIFixture.value(for: "-uiProductsFilter", in: args), let v = ProductFilter(rawValue: f) { list?.filter = v }
        if let q = UIFixture.value(for: "-uiProductsQuery", in: args) { list?.query = q }
        #endif
    }
}

/// 11 的一行：小图 / 首字、名称、两行小字、卖价和「改」竖排
private struct ProductRow: View {
    let item: ProductListItem
    let onEdit: () -> Void

    var body: some View {
        let p = item.product
        HStack(alignment: .top, spacing: 14) {
            Thumb(initial: ProductNaming.isPlaceholder(p.name) ? nil : p.name.first.map(String.init), ref: Thumb.ref(p), size: 64,
                  fill: Tokens.Palette.line.opacity(0.6))
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name)
                    .font(TypeScale.body.weight(.bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("products.row.name")
                if p.archived {
                    Pill(text: "已停用", kind: .outline)
                } else if p.needsReview {
                    HStack(spacing: 6) {
                        Pill(text: "待确认", kind: .outline)
                        Text(ProductsModel.reviewSource(item)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    }
                    Text("进价和库存没填").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                }
                if !p.archived {
                    if let s = ProductsModel.stockLine(item) {
                        FlowLayout(spacing: 8) {
                            Text(s).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                            if let b = ProductsModel.lowStockBadge(item) {
                                Pill(text: b).accessibilityIdentifier("products.row.low")
                            }
                        }
                    }
                    if item.expiring || ProductsModel.earliestText(item) != nil {
                        FlowLayout(spacing: 8) {
                            if item.expiring { Pill(text: "快过期").accessibilityIdentifier("products.row.expiring") }
                            if let e = ProductsModel.earliestText(item) {
                                Text(e).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                            }
                        }
                    }
                    if let k = ProductsModel.packText(item) {
                        Text(k).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 10) {
                PriceText(cents: Int(p.priceFen.raw), size: 36)
                    .accessibilityIdentifier("products.row.price")
                Button(action: onEdit) {
                    Text("改")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(width: 92, height: 64)
                        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tokens.Palette.ink, lineWidth: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityLabel("改 \(p.name)")
                .accessibilityIdentifier("products.row.edit")
            }
        }
        .padding(.vertical, 16)
        .opacity(p.archived ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("products.row.\(p.id.uuidString)")
    }
}

// MARK: - 22 改商品

/// 读好商品再出 22（读库在后台线程）
struct EditProductLoader: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var edit: EditProductModel?

    var body: some View {
        Group {
            if let edit { EditProductView(edit: edit) } else { Tokens.Palette.paper.ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let db = model.db
            guard edit == nil, let d = await EditProductModel.load(db, id) else { return }
            let low = await Task.detached { (try? db.lowStockDefault()) ?? LocalDB.defaultLowStockDefault }.value
            edit = EditProductModel(db: db, detail: d, storeLowDefault: low)
        }
    }
}

struct EditProductView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var edit: EditProductModel
    @FocusState private var focus: Field?
    enum Field: Hashable { case name, price }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "改商品", pendingCount: model.figures.pendingCount, offline: model.offline, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameRow
                    Text("图是查条码时自动下载的；没有图就显示名字的头一个字")
                        .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    priceRow
                    Group {
                        stepperRow("少于几\(edit.unit)提醒快没货", value: $edit.lowAt, range: 0...Int(Limits.maxLowAt), id: "edit.lowAt")
                        divider
                        Toggle(isOn: $edit.trackExpiry) {
                            Text("要管保质期").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                        }
                        .tint(Tokens.Palette.ink)
                        .frame(minHeight: 56)
                        .accessibilityIdentifier("edit.trackExpiry")
                        divider
                        if edit.trackExpiry {
                            stepperRow("提前几天提醒", value: $edit.warnDays, range: 0...Int(Limits.maxExpiryWarnDays), id: "edit.warnDays")
                            divider
                            stepperRow("保质期几个月", value: $edit.shelfMonths, range: 1...Int(Limits.maxShelfLifeMonths), id: "edit.shelfMonths")
                            divider
                        }
                    }
                    ForEach(edit.detail.packs, id: \.barcode) { b in packCard(b) }
                    if let e = edit.error {
                        Text(e).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("edit.error")
                    }
                    PrimaryButton("存好", mode: .neutral, style: .dark) { save() }
                        .accessibilityIdentifier("edit.save")
                        .padding(.top, 8)
                    // 「不卖了」不和「存好」并排，单独一行放在最下面（review-1119-mockups 第 9 条）
                    Button(edit.archived ? "重新卖这个商品" : "不卖了（停用这个商品）") { focus = nil; edit.confirmArchive = true }
                        .font(TypeScale.body)
                        .underline()
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .accessibilityIdentifier("edit.archive")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("好了") { focus = nil }.font(TypeScale.body.weight(.bold)).accessibilityIdentifier("edit.keyboardDone")
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .alert("卖价是 0 元，确定吗？", isPresented: Binding(get: { edit.confirmZeroPrice }, set: { if !$0 { edit.cancelZeroPrice() } })) {
            Button("确定，就卖 0 元") { save(confirmedZero: true) }
            Button("再改改", role: .cancel) { edit.cancelZeroPrice() }
        } message: { Text("顾客扫到这一样会按 ¥0.00 收钱") }
        .confirmSheet(item: $edit.confirmUnlink, page: .products) { ask in
            let b = ask.record
            ConfirmPanel(title: "删掉整\(b.unitName)码 …\(b.barcode.suffix(4))？",
                         message: "删了以后扫这个码就认不出来了，要重新登记。单个的码不受影响。",
                         confirmTitle: "删掉", cancelTitle: "不删了", mode: .neutral, confirmStyle: .dark, confirmImage: "trash",
                         confirmId: "edit.unlink.ok", cancelId: "edit.unlink.cancel",
                         onConfirm: { edit.confirmUnlink = nil; Task { await edit.unlink(b) } },
                         onCancel: { edit.confirmUnlink = nil })
        }
        .confirmSheet(item: Binding(get: { edit.confirmArchive ? ArchiveAsk(on: !edit.archived) : nil },
                                    set: { if $0 == nil { edit.confirmArchive = false } }), page: .products) { a in
            ConfirmPanel(title: a.on ? "不卖了？" : "重新卖这个商品？",
                         message: a.on ? "停用以后，商品列表里放到最后、按名称找不到。扫到这个码还能照卖，会提示「已停用」。"
                                       : "重新放回商品列表，按名称也能找到。",
                         confirmTitle: a.on ? "不卖了" : "重新卖", cancelTitle: a.on ? "还要卖" : "先不了", mode: .neutral,
                         confirmStyle: .dark, confirmImage: nil, confirmId: "edit.archive.ok", cancelId: "edit.archive.cancel",
                         onConfirm: {
                             edit.confirmArchive = false
                             Task { if await edit.setArchived(a.on) { dismiss() } }
                         },
                         onCancel: { edit.confirmArchive = false })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.productEdit")
    }

    struct ArchiveAsk: Identifiable { let on: Bool; var id: Bool { on } }

    private var divider: some View { Rectangle().fill(Tokens.Palette.line).frame(height: 1.5) }

    private var nameRow: some View {
        HStack(spacing: 12) {
            Thumb(initial: ProductNaming.isPlaceholder(edit.product.name) ? nil : edit.product.name.first.map(String.init),
                  ref: Thumb.ref(edit.product), size: 80, fill: Tokens.Palette.line.opacity(0.6))
            TextField("", text: $edit.name, axis: .vertical)
                .font(TypeScale.body.weight(.bold))
                .lineLimit(1...3)
                .focused($focus, equals: .name)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(focus == .name ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2.5))
                .accessibilityIdentifier("edit.name")
        }
    }

    @ViewBuilder private var priceRow: some View {
        let price = VStack(alignment: .leading, spacing: 6) {
            Text("卖多少钱").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            YuanField(text: Binding(get: { edit.price.text }, set: { edit.price = YuanInput($0) }), prompt: "",
                      focused: focus == .price, id: "edit.price")
                .focused($focus, equals: .price)
        }
        let cost = VStack(alignment: .leading, spacing: 6) {
            Text("平均进价").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            ReadOnlyYuan(text: edit.averageCostText)
                .accessibilityIdentifier("edit.averageCost")
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { price; cost }
            VStack(alignment: .leading, spacing: 12) { price; cost }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                Spacer(minLength: 8)
                QuantityStepper(value: value, range: range, compact: true).accessibilityIdentifier(id)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                QuantityStepper(value: value, range: range, compact: true).accessibilityIdentifier(id)
            }
        }
    }

    private func packCard(_ b: BarcodeRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("整\(b.unitName)码 …\(b.barcode.suffix(4))").font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                Text(edit.packLine(b)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { focus = nil; edit.confirmUnlink = .init(record: b) } label: {
                Text("删").font(.system(size: 24, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .frame(width: 88, height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .accessibilityLabel("删整\(b.unitName)码 \(b.barcode)")
            .accessibilityIdentifier("edit.pack.delete")
        }
        .padding(16)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edit.pack.\(b.barcode)")
    }

    private func save(confirmedZero: Bool = false) {
        focus = nil
        Task { if await edit.save(confirmedZero: confirmedZero) { dismiss() } }
    }
}

/// ¥ 金额输入框（系统小数键盘；`YuanInput` 管位数）
struct YuanField: View {
    @Binding var text: String
    let prompt: String
    var focused = false
    /// 辅助功能标识放在输入框本身上（UI 测试直接往里打字）
    var id = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("¥").font(TypeScale.number(26))
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Tokens.Palette.mute).font(TypeScale.secondary))
                .font(TypeScale.number(44))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier(id)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
            .strokeBorder(focused ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2.5))
        .contentShape(Rectangle())
    }
}

/// 平均进价：只读，虚线框（设计稿 22）
private struct ReadOnlyYuan: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if text != "没填" { Text("¥").font(TypeScale.number(26)) }
            Text(text).font(text == "没填" ? TypeScale.body : TypeScale.number(44))
        }
        .foregroundStyle(Tokens.Palette.ink2)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.mute, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text == "没填" ? "平均进价没填" : "平均进价 \(text) 元")
    }
}
