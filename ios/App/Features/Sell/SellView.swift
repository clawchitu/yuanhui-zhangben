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

    /// 推到手输条码页、抹零面板盖着时：相机停、扫码枪不接、扫到的码不收。
    /// 面板 / 手输页一关，`covered` 变回假：`HIDKeyCaptureView.isActive` 变真时当场 `reclaim()` 抢回第一响应者
    /// （不只靠键盘收起的通知），关掉后不点屏幕直接扣扳机照样进（§14 S14-4）
    private var covered: Bool { showManual || showDiscount || model.registerCode != nil }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "卖出", mode: .sell, pendingCount: model.pendingCount, onBack: { dismiss() })
            CameraStrip(hub: hub, permission: permission, paused: covered, torchOn: torchOn, onTorch: toggleTorch,
                        onManual: { showManual = true })
            basketArea
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) { if let n = model.notice { noticeBanner(n) } }
            CheckoutPanel(model: model, onDiscount: { showDiscount = true })
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: model.done)
        .overlay(alignment: .bottomLeading) { probe }
        .scannerInput(hub, active: !covered)
        .refreshesCameraPermission(permission)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.sell.pageId)
        .navigationDestination(isPresented: $showManual) {
            ManualCodeView(db: model.db, mode: .sell, pendingCount: model.pendingCount, fixture: fixture.manual) { code in
                pickManual(code)
            }
        }
        // 扫到没登记的码：家用 04a（→ 04b / 05），收银员 04c。存好了放进购物篮，返回什么都不加
        .navigationDestination(item: $model.registerCode) { req in
            NewProductView(db: model.db, barcode: req.code, mode: fixture.newProduct.mode ?? .sell,
                           quick: model.registration == .quick, canLinkPack: app.capabilities.canSend(.barcodeLink),
                           lookup: app.nameLookup(offline: fixture.offline), pendingCount: model.pendingCount,
                           suggestedProduct: model.focusLine?.conversion.product, fixture: fixture.newProduct) { outcome in
                model.finishRegistration(outcome)
                model.refreshPending()
            }
        }
        .sheet(isPresented: $showDiscount) {
            DiscountPanel(basket: model.basket, mode: .sell, fixtureKeys: fixture.discountKeys,
                          fixtureSubmit: fixture.discountSubmit) { outcome in
                if let outcome { model.applyDiscount(outcome) }
                showDiscount = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let appModel = app
            model.onPendingChange = { appModel.figures.pendingCount = $0 }
            let caps = appModel.capabilities
            model.registration = caps.has(.fullRegister) ? .full : (caps.has(.quickRegister) ? .quick : .none)
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
        .task(id: model.noticeSeq) { await autoDismissNotice() }
        .onChange(of: model.noticeSeq) { _, _ in
            // 抹的零作废：除了黄条，再补一下警告触感、读屏念出来（扫码那一声「嘀」是成功音，光听声音会以为没事，Fable #21）
            guard model.notice == .paidCleared else { return }
            UIAccessibility.post(notification: .announcement, argument: SellModel.Notice.paidCleared.text)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    /// 手输页选中一个：先关页面、恢复收码，再把码交给扫码层（和相机、扫码枪同一条路：同一字符规则、出声）
    private func pickManual(_ code: String) {
        showManual = false
        model.accepting = true
        hub.receive(code, from: .manual)
    }

    // MARK: 购物篮

    @ViewBuilder private var basketArea: some View {
        if model.basket.isEmpty {
            // 03d「记好了」黑卡是虚线框上的浮层，不参与布局（§14 S16-9）：任何字号下都不把顶栏、记账按钮挤出屏幕；
            // 黑卡显示期间空篮只留虚线框
            EmptyBasket(showsContent: model.done == nil)
                .overlay {
                    if let d = model.done {
                        DoneCard(done: d).padding(12).transition(.opacity)
                    }
                }
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

    /// 黄条。「抹的零取消了」比别的黄条更醒目：墨色粗边框、换成撤回图标、停得更久（§14 S16-1，Fable #21）
    private func noticeBanner(_ n: SellModel.Notice) -> some View {
        Button { model.dismissNotice() } label: {
            if n == .paidCleared {
                Banner(kind: .alert, text: n.text, systemImage: "arrow.uturn.backward.circle.fill")
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.banner).strokeBorder(Tokens.Palette.ink, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            } else if n == .quickSaved {
                Banner(kind: .soft, text: n.text, systemImage: "checkmark.circle.fill")
            } else {
                Banner(kind: .alert, text: n.text, systemImage: "exclamationmark.circle.fill")
            }
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
        if !Task.isCancelled { model.dismissDone(id) }
    }

    /// 黄条停 4 秒。按 `noticeSeq` 计时：同样的黄条再出一次（连扫同一个没登记的码）重新数 4 秒，
    /// 不会被上一次的计时提前收掉（Fable 8）
    private func autoDismissNotice() async {
        guard model.notice != nil else { return }
        let seq = model.noticeSeq
        try? await Task.sleep(for: .seconds(model.notice?.seconds ?? 4))
        if !Task.isCancelled { model.dismissNotice(seq: seq) }
    }

    /// 测试夹具（只在 Debug 有内容）：开页后由 FakeScanner 把码喂进扫码层（和真扫码走同一条路：去重、出声），
    /// 喂完改实收、自动记账
    /// 喂码放在独立的 Task 里：推到手输页时页面的 `.task` 会被取消，喂码不能跟着一口气喂完，
    /// 要按时间继续喂（⑨ 的界面测试靠它：在手输页期间扣的扳机不进购物篮）
    private func feedFixture() async {
        guard !fedFixture else { return }
        fedFixture = true
        let (fixture, hub, model) = (fixture, hub, model)
        Task { @MainActor in
            #if DEBUG
            if let scanner = fixture.scanner { await scanner.run(into: hub) }
            #endif
            if let paid = fixture.paidFen { try? model.setPaid(paid) }
            // 抹完零再扫一个（S16-1 黄条截图）：和手输一样走扫码层
            if let code = fixture.scanAfterPaid { hub.receive(code, from: .manual) }
            if fixture.openDiscount { showDiscount = true }
            if fixture.openManual { showManual = true }
            if fixture.autoCommit {
                try? await Task.sleep(for: .milliseconds(200))
                model.commit()
            }
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
                 initial: ProductNaming.isPlaceholder(line.name) ? nil : line.name.first.map(String.init), footerVerticalPadding: 6, compact: true) {
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
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Palette.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.line")
    }

    /// 整件码的行写明单位：「青岛啤酒 500ml · 箱（24 罐）」
    private var title: String {
        line.packQty > 1 ? "\(line.name) · \(line.conversion.unitLabel)" : line.name
    }

    /// 小号步进器：圆钮 46pt、点按区 56pt（S11-4）。点按区上下各多出的 5pt 不撑高这一行（负留白），行距贴稿约 95pt（§14 S16-10）
    private var stepper: some View {
        QuantityStepper(value: count(line, model), range: 0...Int(Limits.maxPackCount), compact: true)
            .accessibilityIdentifier("sell.qty.\(line.barcode)")
            .padding(.vertical, -Self.hitOverhang)
    }

    static let hitOverhang = (QuantityStepper.hitSize(compact: true) - QuantityStepper.diameter(compact: true)) / 2

    private var subtotal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("小计").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            FittingPrice(cents: SellModel.lineAmountFen(line), sizes: [30, 24, 18])
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sell.subtotal")
    }
}

extension SellModel {
    /// 步进器绑的件数：按行 id 每次从篮子里现读（不用界面上那一刻的快照），界面重建前连按两次「+」、
    /// 扫码和「+」交错都在当前数上加（Codex ①）
    func countBinding(for line: Basket.Line) -> Binding<Int> {
        let id = line.id
        return Binding(get: { Int(self.count(lineId: id)) }, set: { self.setCount(lineId: id, $0) })
    }
}

@MainActor
private func count(_ line: Basket.Line, _ model: SellModel) -> Binding<Int> { model.countBinding(for: line) }

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
    /// 黑卡盖在上面时为假：图标和文字不画（只留虚线框），读屏也不读
    var showsContent = true

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
        .opacity(showsContent ? 1 : 0)
        .accessibilityHidden(!showsContent)
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

    /// 放得下就照稿子（对勾、记好了、实收、一句说明）；最大辅助字号下购物篮区矮，依次去掉对勾、收小留白，
    /// 卡片高度不超过购物篮区
    var body: some View {
        ViewThatFits(in: .vertical) {
            card(check: true, vertical: 30)
            card(check: false, vertical: 18)
            card(check: false, vertical: 10, caption: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sell.done")
    }

    private func card(check: Bool, vertical: CGFloat, caption: Bool = true) -> some View {
        VStack(spacing: 10) {
            if check {
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
            }
            Text("记好了").font(.system(size: 30, weight: .bold))
            PriceText(cents: Int(done.paidFen), size: 48, color: .white)
            if caption {
                Text("卖出 \(done.kinds) 样 \(done.items) 件 · 可以扫下一单")
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.card.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, vertical)
        .padding(.horizontal, 20)
        .frame(maxWidth: 310)
        .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.horizontal, 8)
    }
}

// MARK: - 底部结算区

/// 一共几件 / 原价、抹零 / 改总价、要收（或实收）、收好钱了，记账。总价和按钮是固定尺寸。
struct CheckoutPanel: View {
    let model: SellModel
    var onDiscount: () -> Void

    private var empty: Bool { model.basket.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            summaryRow
            // 总价放不下时：64pt 横排 → 48pt 横排 → 才上下排（§14 S16-10）。上下排时「要收」和按钮同一行，总价单独一行
            ViewThatFits(in: .horizontal) {
                // 不放 Spacer：HStack 的间距会在 Spacer 两边各算一次，白占 12pt，¥9999.99 在 48pt 就放不下了
                HStack(alignment: .bottom, spacing: 12) {
                    discountButton
                    totalBlock(Tokens.FixedFontSize.total).frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    discountButton
                    totalBlock(48).frame(maxWidth: .infinity, alignment: .trailing)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        discountButton
                        Spacer(minLength: 0)
                        totalLabel
                    }
                    FittingPrice(cents: model.paidTotalFen, sizes: [Tokens.FixedFontSize.total, 48, 36, 28], color: totalColor)
                        .padding(.bottom, -10)
                        .accessibilityIdentifier("sell.total")
                }
            }
            PrimaryButton("收好钱了，记账", systemImage: "checkmark", mode: .sell) { model.commit() }
                .disabled(!model.canCommit)
                .accessibilityIdentifier("sell.commit")
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
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

    /// 「抹零 / 改总价」：稿子上是 24pt 粗体、约 176×56；字号固定不缩（左右留白收小，不靠 minimumScaleFactor 压字）
    private var discountButton: some View {
        DiscountButton(action: onDiscount)
            .disabled(!model.canChangePaid)
            .accessibilityIdentifier("sell.discount")
    }

    private var totalColor: Color { empty ? Tokens.Palette.mute : Tokens.Palette.ink }

    /// 「要收」/「实收」。抹的零刚被作废（黄条还在）时改成红字「零取消了，按原价收」：
    /// 收银员眼睛盯着总价，黄条在上面容易漏看（§14 S16-1）
    private var totalLabel: some View {
        let cleared = model.notice == .paidCleared
        return Text(cleared ? "零取消了，按原价收" : (model.discountFen == nil ? "要收" : "实收"))
            .font(cleared ? TypeScale.secondary.weight(.bold) : TypeScale.secondary)
            .foregroundStyle(cleared ? Tokens.Palette.sell : Tokens.Palette.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityIdentifier("sell.totalLabel")
    }

    /// 「要收」+ 总价（固定字号，放不下由外层换下一档）
    private func totalBlock(_ size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            totalLabel
            PriceText(cents: Int(model.paidTotalFen), size: size, color: totalColor)
                .padding(.vertical, size >= 64 ? -10 : -7)   // DIN 的行高比字身高出一截，收掉，让总价底边和左边按钮底边齐（03）
                .accessibilityIdentifier("sell.total")
        }
    }
}

/// 结算区的「抹零 / 改总价」描边按钮；不可用时灰边灰字（同 `PrimaryButton` 的置灰样式）
struct DiscountButton: View {
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    static let fontSize: CGFloat = 24
    static let size = CGSize(width: 176, height: 56)

    var body: some View {
        let color = isEnabled ? Tokens.Palette.ink : PrimaryButton.disabledGhost
        Button(action: action) {
            Text("抹零 / 改总价")
                .font(.system(size: Self.fontSize, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(color)
                .frame(width: Self.size.width, height: Self.size.height)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(color, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
    }
}

private extension String {
    var withYuan: String { "¥" + self }
}
