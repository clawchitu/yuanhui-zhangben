import ShopCore
import SwiftUI

/// 读好商品再出 22b（读库在后台线程）
struct ReviewProductLoader: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var review: ReviewProductModel?

    var body: some View {
        Group {
            if let review { ReviewProductView(review: review) } else { Tokens.Palette.paper.ignoresSafeArea() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard review == nil, let d = await EditProductModel.load(model.db, id) else { return }
            let r = ReviewProductModel(db: model.db, detail: d, backend: model.makeReviewBackend())
            #if DEBUG
            r.debugStaleOnce = ProcessInfo.processInfo.arguments.contains("-uiReviewStaleOnce")
            #endif
            review = r
        }
    }
}

/// 22b 补全商品：黄条「收银员登记的，补全后就不再提醒」、名称、卖价、进价（必填）、货架上现在有几个、要管保质期、
/// 「确认，存好」。必须联网；账面数变了（`stale`）弹面板让人重新确认。
struct ReviewProductView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var review: ReviewProductModel
    @FocusState private var focus: Field?
    enum Field: Hashable { case name, price, cost, barcode }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "补全商品", pendingCount: model.figures.pendingCount, offline: model.offline, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Banner(kind: .alert, text: bannerText, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("review.banner")
                    nameRow
                    Text("名称、卖价是\(source)填的，不对可以改")
                        .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    priceAndCost
                    if review.needsBarcode { barcodeRow }
                    stepperRow
                    Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
                    Toggle(isOn: $review.trackExpiry) {
                        Text("要管保质期").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                    }
                    .tint(Tokens.Palette.ink)
                    .frame(minHeight: 56)
                    .accessibilityIdentifier("review.trackExpiry")
                    Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
                    if model.offline {
                        Text("要联网才能补全，连上网再点")
                            .font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                            .accessibilityIdentifier("review.offline")
                    }
                    if let e = review.error {
                        Text(e).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("review.error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("好了") { focus = nil }.font(TypeScale.body.weight(.bold)).accessibilityIdentifier("review.keyboardDone")
                }
            }
            PrimaryButton(review.phase == .submitting ? "正在存…" : "确认，存好", mode: .neutral, style: .dark) {
                focus = nil
                Task { await review.confirm(offline: model.offline) }
            }
            .disabled(review.phase == .submitting)
            .accessibilityIdentifier("review.save")
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Tokens.Palette.paper)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onChange(of: review.phase) { _, p in if p == .done { dismiss() } }
        .alert(review.confirmZero == .cost ? "进价是 0 元，确定吗？" : "卖价是 0 元，确定吗？",
               isPresented: Binding(get: { review.confirmZero != nil }, set: { if !$0 { review.cancelZero() } })) {
            Button(review.confirmZero == .cost ? "确定，是 0 元" : "确定，就卖 0 元") {
                review.acceptZero()
                Task { await review.confirm(offline: model.offline) }
            }
            Button("再改改", role: .cancel) { review.cancelZero() }
        } message: {
            Text(review.confirmZero == .cost ? "货架上这些按 0 元进价记账" : "顾客扫到这一样会按 ¥0.00 收钱")
        }
        .confirmSheet(item: Binding(get: { staleAsk }, set: { if $0 == nil { review.recount() } }), page: .products) { a in
            ConfirmPanel(title: "账上现在是 \(a.qty) \(review.unit)",
                         message: "刚才别的手机又记了账。你数的 \(review.counted) \(review.unit)还对吗？",
                         confirmTitle: "对，就是 \(review.counted) \(review.unit)", cancelTitle: "再数一下", mode: .neutral,
                         confirmStyle: .dark, confirmId: "review.stale.ok", cancelId: "review.stale.recount",
                         busy: review.phase == .submitting,
                         onConfirm: { Task { await review.confirmStale() } },
                         onCancel: { review.recount() })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.productReview")
    }

    struct StaleAsk: Identifiable { let qty: Int64; let ver: Int64; var id: Int64 { ver } }

    private var staleAsk: StaleAsk? {
        if case .stale(let q, let v) = review.phase { return StaleAsk(qty: q, ver: v) }
        return nil
    }

    /// 自动建的（卖价 0、没单件码，§14 S05-9）不是收银员登记的
    private var source: String {
        review.product.priceFen == .zero && !review.detail.hasUnitBarcode ? "卖出时自动" : "收银员"
    }

    private var bannerText: String {
        source == "收银员" ? "收银员登记的，补全后就不再提醒" : "卖出时自动建的，补全后就不再提醒"
    }

    private var nameRow: some View {
        HStack(spacing: 12) {
            Thumb(initial: ProductNaming.isPlaceholder(review.product.name) ? nil : review.product.name.first.map(String.init),
                  ref: Thumb.ref(review.product), size: 80, fill: Tokens.Palette.line.opacity(0.6))
            TextField("", text: $review.name, axis: .vertical)
                .font(TypeScale.body.weight(.bold))
                .lineLimit(1...3)
                .focused($focus, equals: .name)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(focus == .name ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2.5))
                .accessibilityIdentifier("review.name")
        }
    }

    @ViewBuilder private var priceAndCost: some View {
        let price = VStack(alignment: .leading, spacing: 6) {
            Text("卖多少钱").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            YuanField(text: Binding(get: { review.price.text }, set: { review.price = YuanInput($0) }), prompt: "先填卖价",
                      focused: focus == .price, id: "review.price")
                .focused($focus, equals: .price)
        }
        let cost = VStack(alignment: .leading, spacing: 6) {
            Text("进价（每\(review.unit)）").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            YuanField(text: Binding(get: { review.cost.text }, set: { review.cost = YuanInput($0) }), prompt: "要填",
                      focused: focus == .cost, id: "review.cost")
                .focused($focus, equals: .cost)
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { price; cost }
            VStack(alignment: .leading, spacing: 12) { price; cost }
        }
    }

    private var barcodeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("条码（没有单个的码，扫一下或者手输；不知道就空着）")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $review.barcode, prompt: Text("扫码或手输").foregroundStyle(Tokens.Palette.mute))
                .font(TypeScale.number(32))
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .barcode)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(focus == .barcode ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2.5))
                .accessibilityIdentifier("review.barcode")
        }
    }

    private var stepperRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("货架上现在有几\(review.unit)").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                Spacer(minLength: 8)
                QuantityStepper(value: $review.counted, range: 0...9999, compact: true)
                    .accessibilityIdentifier("review.counted")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("货架上现在有几\(review.unit)").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                QuantityStepper(value: $review.counted, range: 0...9999, compact: true)
                    .accessibilityIdentifier("review.counted")
            }
        }
    }
}
