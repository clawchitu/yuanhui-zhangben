import ShopCore
import SwiftUI
import UIKit

/// 进货页（06a / 06b / 06c）。
///
/// 从上到下：靛青顶栏（返回、进货、N 笔待传）→ 还没扫到东西时是相机条和一句说明；扫到之后是可滚动的内容
/// （商品卡、「进了几箱 / 每箱多少钱」、蓝卡、管保质期时的到期日区）→ 钉在底部的自家键盘（正在填的时候）和「记进货」。
/// 「记进货」任何字号下都固定在底部可见；填年月日时换成「填好了」（06c），按了收起键盘。
/// 扫码枪随时可扫：换一个码就换一个商品（没记的输入作废）。页面上没有系统键盘的输入框，扫码枪的数字不会打进框里。
struct StockInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: StockInModel
    @State private var permission: CameraPermission
    @State private var hub = ScanHub(feedback: ScanFeedback.shared)
    @State private var torchOn = false
    @State private var showManual = false
    @State private var fedFixture = false
    private let fixture: SellFixture

    init(db: LocalDB, clock: @escaping () -> Date, fixture: SellFixture) {
        _model = State(initialValue: StockInModel(db: db, clock: clock))
        _permission = State(initialValue: CameraPermission(forced: fixture.camera))
        self.fixture = fixture
    }

    private var covered: Bool { showManual || model.registerCode != nil || model.confirmZeroCost || model.confirmDate }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "进货", mode: .stock, pendingCount: model.pendingCount, onBack: { dismiss() })
            if model.conversion == nil {
                CameraStrip(hub: hub, permission: permission, paused: covered, torchOn: torchOn, onTorch: toggleTorch,
                            onManual: { showManual = true })
                emptyHint.frame(maxHeight: .infinity, alignment: .top)
            } else {
                form
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .overlay(alignment: .top) { if let n = model.notice { noticeBanner(n).padding(.top, 60) } }
        .overlay(alignment: .bottomLeading) { probe }
        .scannerInput(hub, active: !covered)
        .refreshesCameraPermission(permission)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.stockIn.pageId)
        .navigationDestination(isPresented: $showManual) {
            ManualCodeView(db: model.db, mode: .stock, pendingCount: model.pendingCount, fixture: fixture.manual) { code in
                showManual = false
                model.accepting = true
                hub.receive(code, from: .manual)
            }
        }
        // 进货中遇到新商品：04a → 必须走完 04b（从进货进来没有「存好，接着卖」）；或 05 挂成整箱后接着进货
        .navigationDestination(item: $model.registerCode) { req in
            NewProductView(db: model.db, barcode: req.code, mode: .stock, quick: false,
                           canLinkPack: app.capabilities.canSend(.barcodeLink),
                           lookup: app.nameLookup(offline: fixture.offline), pendingCount: model.pendingCount,
                           suggestedProduct: nil, fixture: fixture.newProduct) { outcome in
                model.finishRegistration(outcome)
            }
        }
        .alert("进价是 0 元，确定吗？", isPresented: Binding(get: { model.confirmZeroCost },
                                                       set: { if !$0 { model.cancelZeroCost() } })) {
            Button("确定，是 0 元") { model.commit(confirmedZero: true) }
            Button("再改改", role: .cancel) { model.cancelZeroCost() }
        } message: {
            Text("这批货按 0 元进价记账")
        }
        .alert("日子对吗？", isPresented: Binding(get: { model.confirmDate }, set: { if !$0 { model.cancelDate() } })) {
            Button("没错，就这样记") { model.commit(confirmedZero: true, confirmedDate: true) }
            Button("再改改", role: .cancel) { model.cancelDate() }
        } message: {
            Text(model.dateWarning ?? "")
        }
        .onAppear {
            let appModel = app
            model.onPendingChange = { appModel.figures.pendingCount = $0 }
            model.canRegister = appModel.capabilities.has(.fullRegister)
            let model = model
            hub.handler = { model.handle($0) }
            model.accepting = !covered
        }
        .onChange(of: covered) { _, c in model.accepting = !c }
        .onDisappear { if torchOn { _ = Torch.set(false); torchOn = false } }
        .task { await feedFixture() }
        .task(id: model.noticeSeq) { await autoDismissNotice() }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 40, weight: .semibold)).foregroundStyle(Tokens.Palette.stock)
                .accessibilityHidden(true)
            Text("扫一下送来的货").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
            Text("整箱、整条的码按整箱算；扫码枪也行").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .accessibilityIdentifier("stockIn.empty")
    }

    // MARK: 表单

    private var form: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    productCard
                    fields.id("fields")
                    if let p = model.problem {
                        Text(p).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("stockIn.problem")
                    }
                    if model.showsExpiry { expirySection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("stockIn.scroll")
            // 放不下时把正在填的那一格滚到看得见的地方（商品卡往上滚，「记好了」里会再报一次商品名）：
            // 填数量 / 单价时是这两格，填年月日时是日期格
            .onAppear { scroll(proxy) }
            .onChange(of: model.active) { _, _ in scroll(proxy) }
            .onChange(of: model.conversion) { _, _ in scroll(proxy) }
            }
            // 蓝卡钉在键盘上面：任何字号下填数时都看得见一共多少、入账多少（06a）
            if !model.editingDate {
                blueCard
                    .dynamicTypeSize(...DiscountPanel.labelCap)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
            if model.active != nil {
                Keypad(showsDot: model.keypadShowsDot) { model.key($0) }
                    .accessibilityIdentifier("stockIn.keypad")
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            Group {
                if model.editingDate {
                    PrimaryButton("填好了", mode: .stock) { model.doneEditing() }
                        .accessibilityIdentifier("stockIn.doneEditing")
                } else {
                    PrimaryButton("记进货", systemImage: "checkmark", mode: .stock) { model.commit() }
                        .disabled(!model.canCommit)
                        .accessibilityIdentifier("stockIn.commit")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Tokens.Palette.paper)
            // 底部按钮的高度先保住，放不下时让上面的表单滚动、压缩（PR #31 Codex 2）
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let f = model.active else { return }
        let target = [.qty, .cost].contains(f) ? "fields" : "dates"
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .bottom) }
    }

    private var productCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumb(initial: model.product.flatMap { ProductNaming.isPlaceholder($0.name) ? nil : $0.name.first.map(String.init) },
                  size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.product?.name ?? "").font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stockIn.name")
                Text(model.cardSubtitle).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stockIn.subtitle")
                if let b = model.packBadge {
                    Text(b).font(TypeScale.secondary.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: Tokens.Radius.pill))
                        .accessibilityIdentifier("stockIn.badge")
                }
            }
            Spacer(minLength: 0)
            Button { model.clear() } label: {
                Text("重新扫").font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Tokens.Palette.stock)
                    .frame(minWidth: Tokens.Size.minHitTarget, minHeight: Tokens.Size.minHitTarget)
            }
            .accessibilityIdentifier("stockIn.rescan")
        }
        .padding(14)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
    }

    private var fields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) { qtyBox; costBox }
            VStack(alignment: .leading, spacing: 12) { qtyBox; costBox }
        }
    }

    private var qtyBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(model.qtyLabel)
            inputBox(model.qtyText, field: .qty, placeholder: "0").accessibilityIdentifier("stockIn.qty")
        }
    }

    private var costBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(model.costLabel)
            inputBox(model.cost.text, field: .cost, placeholder: "¥0", prefix: "¥").accessibilityIdentifier("stockIn.cost")
        }
    }

    private func inputBox(_ text: String, field: StockInModel.Field, placeholder: String, prefix: String? = nil) -> some View {
        let on = model.active == field
        return Button { model.focus(field) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let prefix, !text.isEmpty { Text(prefix).font(TypeScale.number(24)) }
                Text(text.isEmpty ? placeholder : text).font(TypeScale.number(40))
                    .foregroundStyle(text.isEmpty ? Tokens.Palette.mute : Tokens.Palette.ink)
                if on { Rectangle().fill(Tokens.Palette.stock).frame(width: 2.5, height: 36).accessibilityHidden(true) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(on ? Tokens.Palette.stock : Tokens.Palette.line, lineWidth: on ? 2.5 : 2))
        }
        .buttonStyle(.plain)
        .accessibilityValue(text)
    }

    /// 蓝卡：一共 / 入账多少、每个进价 / 加上原来的平均（预计）
    private var blueCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 大字 / 最大辅助字号下商品卡会滚出首屏：蓝卡顶上带一行商品名，填钱时看得见是哪一样（PR #31 Fable 建议 1，同 S18-3）
            if typeSize >= .xxxLarge, let p = model.product {
                Text(p.name).font(TypeScale.secondary.weight(.semibold)).foregroundStyle(Tokens.Palette.ink2)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("stockIn.cardName")
            }
            HStack(alignment: .lastTextBaseline) {
                Text("一共").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
                Spacer(minLength: 8)
                Text(model.totalText ?? "¥0.00").font(TypeScale.price).minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(model.totalText == nil ? Tokens.Palette.mute : Tokens.Palette.ink)
                    .accessibilityIdentifier("stockIn.total")
            }
            if let l = model.entryLine {
                Text(l).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stockIn.entryLine")
            } else {
                Text("填上\(model.qtyLabel.dropFirst(2))和多少钱，这里算总价")
                    .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let a = model.averageLine {
                Text(a).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stockIn.average")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.stockTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    // MARK: 保质期（06b / 06c）

    private var expirySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Tokens.Palette.line)
            ViewThatFits(in: .horizontal) {
                HStack { expiryTitle; Spacer(); unknownButton }
                VStack(alignment: .leading, spacing: 6) { expiryTitle; unknownButton }
            }
            if model.expiryUnknown {
                Text("这批的到期日先不填，以后进货时再填").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("stockIn.expiryUnknownNote")
            } else {
                if !model.editingDate { modePicker }
                dateBoxes.id("dates")
                if model.editingDate {
                    Text("年份默认今年；月、日填满两位自动跳下一格").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.expiryMode == .produced && !model.editingDate || model.active == .months { monthsRow }
                if model.expiryMode == .produced && !model.editingDate { computedRow }
            }
        }
    }

    private var expiryTitle: some View {
        Text("这批的保质期").font(TypeScale.title.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
    }

    private var unknownButton: some View {
        Button { model.expiryUnknown.toggle(); if model.expiryUnknown { model.doneEditing() } } label: {
            Text(model.expiryUnknown ? "还是填一下" : "不知道，先不填").font(TypeScale.body.weight(.semibold)).underline()
                .foregroundStyle(Tokens.Palette.ink).frame(minHeight: Tokens.Size.minHitTarget)
        }
        .accessibilityIdentifier("stockIn.expiryUnknown")
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeChip("直接填到期日", .direct)
            modeChip("填生产日期", .produced)
        }
        .padding(4)
        .background(Tokens.Palette.line.opacity(0.7), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private func modeChip(_ title: String, _ m: StockInModel.ExpiryMode) -> some View {
        let on = model.expiryMode == m
        return Button { model.expiryMode = m } label: {
            Text(title).font(TypeScale.body.weight(on ? .bold : .regular)).foregroundStyle(Tokens.Palette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.minHitTarget)
                .background(on ? Tokens.Palette.card : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.card - 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(m == .direct ? "stockIn.modeDirect" : "stockIn.modeProduced")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var dateBoxes: some View {
        HStack(spacing: 10) {
            dateBox(model.year, "年", .year, placeholder: "年")
            dateBox(model.month, "月", .month, placeholder: "")
            dateBox(model.day, "日", .day, placeholder: "")
        }
    }

    private func dateBox(_ text: String, _ unit: String, _ field: StockInModel.Field, placeholder: String) -> some View {
        let on = model.active == field
        return Button { model.focus(field) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text.isEmpty ? placeholder : text).font(TypeScale.number(36)).foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if on { Rectangle().fill(Tokens.Palette.stock).frame(width: 2.5, height: 30).accessibilityHidden(true) }
                Text(unit).font(.system(size: 17)).foregroundStyle(Tokens.Palette.ink2)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(on ? Tokens.Palette.stock : Tokens.Palette.line, lineWidth: on ? 2.5 : 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stockIn.\(field)")
        .accessibilityValue(text)
    }

    private var monthsRow: some View {
        HStack {
            Text(model.monthsText.isEmpty ? "保质期还没填几个月" : "保质期 \(model.monthsText) 个月")
                .font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("stockIn.months")
            Spacer()
            Button { model.focus(.months) } label: {
                Text("改").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                    .frame(minWidth: Tokens.Size.minHitTarget, minHeight: Tokens.Size.minHitTarget)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.key).strokeBorder(Tokens.Palette.ink, lineWidth: 2))
            }
            .accessibilityIdentifier("stockIn.editMonths")
        }
    }

    private var computedRow: some View {
        HStack {
            Text("算出来到期").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
            Spacer()
            Text(model.computedExpiry?.description ?? "—").font(TypeScale.number(34)).foregroundStyle(Tokens.Palette.ink)
                .accessibilityIdentifier("stockIn.computed")
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.stock, lineWidth: 2))
    }

    private func label(_ s: String) -> some View {
        Text(s).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private func noticeBanner(_ n: StockInModel.Notice) -> some View {
        Banner(kind: n.isError ? .alert : .soft, text: n.text,
               systemImage: n.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .padding(.horizontal, 20)
            .accessibilityIdentifier("stockIn.notice")
    }

    private func toggleTorch() {
        if let now = Torch.set(!torchOn) { torchOn = now }
    }

    private func autoDismissNotice() async {
        guard model.notice != nil, !fixture.holdDone else { return }
        let seq = model.noticeSeq
        try? await Task.sleep(for: .seconds(4))
        if !Task.isCancelled { model.dismissNotice(seq: seq) }
    }

    @ViewBuilder private var probe: some View {
        #if DEBUG
        if fixture.probe {
            let text = StockInProbe.describe(db: model.db, commits: model.commitCount)
            Text(text)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityLabel(text)
                .accessibilityIdentifier("debug.ledger")
        }
        #endif
    }

    /// 测试夹具（只在 Debug 有内容）：喂码、预填数量 / 单价 / 到期日、选中某一格、自动按「记进货」
    private func feedFixture() async {
        guard !fedFixture else { return }
        fedFixture = true
        let (fixture, hub, model) = (fixture, hub, model)
        Task { @MainActor in
            #if DEBUG
            if let scanner = fixture.scanner { await scanner.run(into: hub) }
            let f = fixture.stockIn
            if model.conversion != nil {
                model.fill(qty: f.qty, cost: f.cost)
                if let m = f.expiryMode { model.expiryMode = m == "direct" ? .direct : .produced }
                if let d = f.date { model.fillDate(d, months: f.months) } else if let m = f.months { model.fillDate("", months: m) }
                if f.unknown { model.expiryUnknown = true }
                if let fld = f.field { model.active = fld == "none" ? nil : StockInFixture.field(fld) }
                if f.commit {
                    try? await Task.sleep(for: .milliseconds(200))
                    model.commit(confirmedZero: f.confirmZero)
                }
            }
            #endif
        }
    }
}

/// 进货页的测试夹具（`-uiStockQty 5 -uiStockCost 48 -uiStockMode direct|produced -uiStockDate 2026-11-12
/// -uiStockMonths 6 -uiStockField qty|cost|year|month|day|months|none -uiStockUnknown -uiStockCommit -uiStockConfirmZero`）
struct StockInFixture: Equatable, Sendable {
    var qty: String?
    var cost: String?
    var expiryMode: String?
    var date: String?
    var months: String?
    var field: String?
    var unknown = false
    var commit = false
    var confirmZero = false
    static let none = StockInFixture()

    static func field(_ s: String) -> StockInModel.Field? {
        switch s {
        case "qty": .qty
        case "cost": .cost
        case "year": .year
        case "month": .month
        case "day": .day
        case "months": .months
        default: nil
        }
    }
}

#if DEBUG
/// 进货页的调试探针：outbox 里的进货 op（件数、换算、每件单价、到期日）和临时库存，UI 测试按 `key=value` 读
enum StockInProbe {
    static func describe(db: LocalDB, commits: Int) -> String {
        do {
            let ops = try db.allOutbox().filter { $0.type == .stockIn }
            var parts = ["stockIns=\(ops.count)", "commits=\(commits)"]
            if let last = ops.last,
               let obj = try JSONSerialization.jsonObject(with: last.opJSON) as? [String: Any],
               let p = obj["payload"] as? [String: Any] {
                parts.append("lastPackCount=\(p["pack_count"] ?? "")")
                parts.append("lastPackQty=\(p["pack_qty"] ?? "")")
                parts.append("lastUnitCost=\(p["unit_cost_fen"] ?? "")")
                parts.append("lastExpiry=\(p["expiry_date"] ?? "none")")
                if let id = (p["product_id"] as? String).flatMap(UUID.init(uuidString:)), let s = try db.displayStock(id) {
                    parts.append("lastStock=\(s.qty)")
                }
            }
            return (parts + SellProbe.registrationCounts(db)).joined(separator: ";")
        } catch {
            return "error=\(error)"
        }
    }
}
#endif
