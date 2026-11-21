import ShopCore
import SwiftUI
import UIKit

/// 卖出页（03 / 03b / 03c / 03d / 24b / 27a）。
///
/// 从上到下：朱红顶栏（返回、卖出、N 笔待传）→ 相机条（常开，固定高）→ 购物篮（刚扫的在价签里，其余两行式往下排；
/// 空篮是虚线框）→ 底部结算区（一共几件、抹零 / 改总价、要收、收好钱了，记账）。
/// 结算区固定在底部、不随购物篮滚动：系统最大辅助字号下总价和记账按钮也完整可见。
/// 屏幕常亮（`isIdleTimerDisabled`）只在这一页打开，离开就关。
struct SellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: SellModel
    @State private var permission: CameraPermission
    /// 卖出页自己的扫码汇合点；提示音全 App 共用一个（`ScanFeedback.shared`，§14 S14-3 ⑪）
    @State private var hub = ScanHub(feedback: ScanFeedback.shared)
    @State private var torchOn = false
    @State private var showManual = false
    @State private var showDiscount = false
    @State private var fedFixture = false
    private let fixture: SellFixture

    init(db: LocalDB, fixture: SellFixture) {
        _model = State(initialValue: SellModel(db: db))
        _permission = State(initialValue: CameraPermission(forced: fixture.camera))
        self.fixture = fixture
    }

    /// 推到手输条码 / 抹零页（S17 换成面板后同样算「盖住」）：相机停、扫码枪不接、扫到的码不收
    private var covered: Bool { showManual || showDiscount }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "卖出", mode: .sell, pendingCount: model.pendingCount, onBack: { dismiss() })
            CameraStrip(hub: hub, permission: permission, paused: covered, torchOn: torchOn, onTorch: toggleTorch,
                        onManual: { showManual = true })
            ZStack(alignment: .top) {
                basketArea
                if let n = model.notice { noticeBanner(n) }
                if let d = model.done { DoneCard(done: d).padding(.top, 150).transition(.opacity) }
            }
            .frame(maxHeight: .infinity)
            CheckoutPanel(model: model, onDiscount: { showDiscount = true })
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: model.done)
        .overlay(alignment: .bottomLeading) { probe }
        .scannerInput(hub, active: !covered)
        .refreshesCameraPermission(permission)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.sell.pageId)
        .navigationDestination(isPresented: $showManual) { RouteView(route: .manualCode) }
        .navigationDestination(isPresented: $showDiscount) { RouteView(route: .discount) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let appModel = app
            model.onPendingChange = { appModel.figures.pendingCount = $0 }
            let model = model
            hub.handler = { model.handle($0) }
            model.accepting = !covered
        }
        .onChange(of: covered) { _, c in model.accepting = !c }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if torchOn { _ = Torch.set(false); torchOn = false }
        }
        .task { await feedFixture() }
        .task(id: model.done?.id) { await autoDismissDone() }
        .task(id: model.notice) { await autoDismissNotice() }
    }

    // MARK: 购物篮

    @ViewBuilder private var basketArea: some View {
        if model.basket.isEmpty {
            EmptyBasket()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if let f = model.focusLine { FocusLineCard(line: f, model: model).padding(.bottom, 4) }
                    ForEach(model.otherLines) { BasketLineRow(line: $0, model: model) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("sell.basket")
        }
    }

    private func noticeBanner(_ n: SellModel.Notice) -> some View {
        Button { model.dismissNotice() } label: {
            Banner(kind: .alert, text: n.text, systemImage: "exclamationmark.circle.fill")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .accessibilityIdentifier("sell.notice")
    }

    // MARK: 动作

    private func toggleTorch() {
        if let now = Torch.set(!torchOn) { torchOn = now }
    }

    /// 「记好了」黑卡停 2.5 秒；下一次扫码会立刻把它换掉
    private func autoDismissDone() async {
        guard let id = model.done?.id, !fixture.holdDone else { return }
        try? await Task.sleep(for: .seconds(2.5))
        model.dismissDone(id)
    }

    private func autoDismissNotice() async {
        guard model.notice != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        if !Task.isCancelled { model.dismissNotice() }
    }

    /// 测试夹具（只在 Debug 有内容）：开页后由 FakeScanner 把码喂进扫码层（和真扫码走同一条路：去重、出声），
    /// 喂完改实收、自动记账
    private func feedFixture() async {
        guard !fedFixture else { return }
        fedFixture = true
        #if DEBUG
        if let scanner = fixture.scanner { await scanner.run(into: hub) }
        #endif
        if let paid = fixture.paidFen { try? model.setPaid(paid) }
        if fixture.autoCommit {
            try? await Task.sleep(for: .milliseconds(200))
            model.commit()
        }
    }

    /// 调试探针（`-uiProbe`，只在 Debug）：把本地库里卖出批次和 outbox 的情况写在一个看不见的元素上，UI 测试读它
    @ViewBuilder private var probe: some View {
        #if DEBUG
        if fixture.probe {
            let text = SellProbe.describe(db: model.db, commits: model.commitCount)
            Text(text)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityLabel(text)
                .accessibilityIdentifier("debug.ledger")
        }
        #endif
    }
}

// MARK: - 价签（刚扫的那一行）

/// 03 最上面的黄色价签：缩略图（没图用首字）、名称、单价，下面一栏「买几个」大号步进器。
struct FocusLineCard: View {
    let line: Basket.Line
    let model: SellModel

    var body: some View {
        PriceTag(name: line.name, caption: caption, unitPriceCents: Int(SellModel.unitPriceFen(line)),
                 initial: line.name.first.map(String.init), footerVerticalPadding: 6) {
            HStack {
                Text("买几个").font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                Spacer(minLength: 8)
                QuantityStepper(value: count(line, model), range: 0...Int(Limits.maxPackCount))
                    .accessibilityIdentifier("sell.qty.focus")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.tag")
    }

    /// 「刚扫的 · 单价」；整件码写明 1 件是几个（「刚扫的 · 每箱（24 罐）」）；已停用的商品照卖，标一句
    private var caption: String { Self.caption(for: line) }

    static func caption(for line: Basket.Line) -> String {
        var s = line.packQty > 1 ? "刚扫的 · 每\(line.conversion.unitLabel)" : "刚扫的 · 单价"
        if line.conversion.product.archived { s += " · 已停用" }
        return s
    }
}

/// 价签以外的各行（两行式）：第一行名称（长名换行，不截断）；第二行小号步进器 + 小计。
struct BasketLineRow: View {
    let line: Basket.Line
    let model: SellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TypeScale.body.weight(.medium))
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stepper
                    Spacer(minLength: 4)
                    subtotal
                }
                VStack(alignment: .trailing, spacing: 2) {
                    stepper.frame(maxWidth: .infinity, alignment: .leading)
                    subtotal
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Palette.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.line")
    }

    /// 整件码的行写明单位：「青岛啤酒 500ml · 箱（24 罐）」
    private var title: String {
        line.packQty > 1 ? "\(line.name) · \(line.conversion.unitLabel)" : line.name
    }

    private var stepper: some View {
        QuantityStepper(value: count(line, model), range: 0...Int(Limits.maxPackCount), compact: true)
            .accessibilityIdentifier("sell.qty.\(line.barcode)")
    }

    private var subtotal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("小计").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            FittingPrice(cents: SellModel.lineAmountFen(line), sizes: [30, 24, 18])
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sell.subtotal")
    }
}

@MainActor
private func count(_ line: Basket.Line, _ model: SellModel) -> Binding<Int> {
    Binding(get: { Int(line.packCount) }, set: { model.setCount(lineId: line.id, $0) })
}

/// 金额按给定的几档字号从大到小试，放得下哪档用哪档：金额再长也不出右边距
struct FittingPrice: View {
    let cents: Int64
    var sizes: [CGFloat]
    var color: Color = Tokens.Palette.ink

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(sizes, id: \.self) { PriceText(cents: Int(cents), size: $0, color: color) }
        }
    }
}

// MARK: - 空篮（03c）

struct EmptyBasket: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Tokens.Palette.ink2)
                .accessibilityHidden(true)
            Text("扫第一样商品")
                .font(TypeScale.title.weight(.bold))
                .foregroundStyle(Tokens.Palette.ink)
            Text("条码对准上面的框\n或者用扫码枪扫")
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
            .strokeBorder(Tokens.Palette.mute, style: StrokeStyle(lineWidth: 2.5, dash: [8, 7])))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sell.empty")
    }
}

// MARK: - 记好了（03d）

struct DoneCard: View {
    let done: SellModel.Done

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
            Text("记好了").font(.system(size: 30, weight: .bold))
            PriceText(cents: Int(done.paidFen), size: 48, color: .white)
            Text("卖出 \(done.kinds) 样 \(done.items) 件 · 可以扫下一单")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.card.opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .frame(maxWidth: 310)
        .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sell.done")
    }
}

// MARK: - 底部结算区

/// 一共几件 / 原价、抹零 / 改总价、要收（或实收）、收好钱了，记账。总价和按钮是固定尺寸。
struct CheckoutPanel: View {
    let model: SellModel
    var onDiscount: () -> Void

    private var empty: Bool { model.basket.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summaryRow
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    discountButton
                    Spacer(minLength: 0)
                    totalBlock
                }
                VStack(alignment: .trailing, spacing: 8) {
                    totalBlock
                    discountButton.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            PrimaryButton("收好钱了，记账", systemImage: "checkmark", mode: .sell) { model.commit() }
                .disabled(!model.canCommit)
                .accessibilityIdentifier("sell.commit")
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Tokens.Palette.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Palette.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.checkout")
    }

    /// 「一共 6 件」；抹过零时加「原价 ¥53.50」（划掉）和右边的「优惠 ¥0.50」（03b）
    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("一共 \(model.itemCount) 件")
                .accessibilityIdentifier("sell.itemCount")
            if model.discountFen != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("原价")
                    Text(Money.yuanString(Int(model.listTotalFen)).withYuan)
                        .font(TypeScale.number(18))
                        .strikethrough()
                }
            }
            Spacer(minLength: 0)
            if let d = model.discountFen {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(d >= 0 ? "优惠" : "多收")
                    Text(Money.yuanString(Int(d.magnitude)).withYuan).font(TypeScale.number(18)).foregroundStyle(Tokens.Palette.ink)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sell.discountAmount")
            }
        }
        .font(TypeScale.secondary)
        .foregroundStyle(Tokens.Palette.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var discountButton: some View {
        PrimaryButton("抹零 / 改总价", style: .ghost, size: .small, action: onDiscount)
            .frame(width: 180)
            .disabled(!model.canChangePaid)
            .accessibilityIdentifier("sell.discount")
    }

    private var totalBlock: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(model.discountFen == nil ? "要收" : "实收")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
            FittingPrice(cents: model.paidTotalFen, sizes: [Tokens.FixedFontSize.total, 48, 36, 28],
                         color: empty ? Tokens.Palette.mute : Tokens.Palette.ink)
                .padding(.vertical, -7)   // DIN 的行高比字身高出一截，收掉，让总价底边和左边按钮底边齐（03）
                .padding(.top, 4)
                .accessibilityIdentifier("sell.total")
        }
    }
}

private extension String {
    var withYuan: String { "¥" + self }
}
