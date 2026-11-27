import ShopCore
import SwiftUI

/// 盘点（12a / 12b）。
///
/// - 进来先把本机的账传完、跟服务器对一次（必须联网）；连不上整页只写「要联网才能盘点」和「再试一次」。
/// - 等扫码：顶上进度「已经数了 N 种 / 还有 M 种」，中间一句「扫一个商品，数一数货架上有几个」，下面相机区（扫码枪、手输随时可用）。
/// - 扫到（12a）：商品卡（账上还有 N）→「货架上实际数了几罐」+ 框 + 黄条「比账上少 1 罐」+ 自家数字键盘（没有小数点）
///   →「没错」/「存好，扫下一个」。相机区收起；扫码枪、手输换一个码就换一个商品（没存的数作废）。
/// - 另一台手机这期间记了账：弹「账上现在是 N 罐，你数的还对吗」，「对，就是 X 罐」带新版本交，「再数一下」回去改。
/// - 12b「还有 M 种没数」：点顶上的「还有 M 种」或等扫码时按返回进来；「去数」直接填，「接着扫码数」回来，「先到这里，结束盘点」离开。
///   没数的按账上算，什么都不改。
struct CountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: CountModel
    @State private var permission: CameraPermission
    @State private var hub = ScanHub(feedback: ScanFeedback.shared)
    @State private var torchOn = false
    @State private var showManual = false
    @State private var fedFixture = false
    @State private var started = false
    @State private var finishing = false
    private let fixture: SellFixture

    init(db: LocalDB, backend: CountBackend?, clock: @escaping () -> Date, fixture: SellFixture) {
        _model = State(initialValue: CountModel(db: db, backend: backend, clock: clock))
        _permission = State(initialValue: CameraPermission(forced: fixture.camera))
        self.fixture = fixture
    }

    private var cardOpen: Bool { model.item != nil }
    private var covered: Bool { showManual || model.showList || model.staleQuestion != nil }
    /// 相机只在等扫码、页面没被盖住时开
    private var cameraOn: Bool { model.phase == .ready && !cardOpen && !covered }

    var body: some View {
        GeometryReader { geo in
            let layout = ScanLayout(size: geo.size, insets: geo.safeAreaInsets, compact: typeSize.isAccessibilitySize)
            VStack(spacing: 0) {
                ModeBar(title: model.title, pendingCount: statusCount, offline: model.phase == .offline, onBack: back)
                // 提示放在顶栏下面占位（不盖住进度和商品卡）
                if let n = model.notice { noticeBanner(n).padding(.top, 6) }
                switch model.phase {
                case .connecting: connecting
                case .offline: offline
                default:
                    if model.item != nil {
                        card
                    } else {
                        progressHeader.padding(.horizontal, 20).padding(.top, 10)
                        emptyHint.frame(maxWidth: .infinity, maxHeight: .infinity)
                        CameraStrip(hub: hub, permission: permission, paused: !cameraOn, torchOn: torchOn, layout: layout,
                                    onTorch: toggleTorch, onManual: { showManual = true })
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .scannerInput(hub, active: model.phase == .ready && !covered)
        .refreshesCameraPermission(permission)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.count.pageId)
        .navigationDestination(isPresented: $showManual) {
            ManualCodeView(db: model.db, mode: .neutral, fixture: fixture.manual) { code in
                showManual = false
                hub.receive(code, from: .manual)
            }
        }
        .navigationDestination(isPresented: $model.showList) {
            CountListView(model: model, onFinish: { finishing = true; model.showList = false })
        }
        // 12b「先到这里，结束盘点」：12b 先退回来，再离开盘点页（同时退两层，导航栈会只退一层）
        .onChange(of: model.showList) { _, open in
            if !open, finishing { finishing = false; dismiss() }
        }
        .alert(model.staleQuestion ?? "", isPresented: Binding(get: { model.staleQuestion != nil }, set: { _ in })) {
            Button("对，就是 \(model.text.isEmpty ? "0" : model.text) \(model.item?.unit ?? "个")") { Task { await model.confirmStale() } }
            Button("再数一下", role: .cancel) { model.recount() }
        } message: {
            Text("刚才另一台手机记了账")
        }
        .onAppear {
            let appModel = app, model = model
            model.onSaved = { appModel.refreshRecent() }
            model.onCardClosed = { [weak hub] in hub?.inputResumed() }
            hub.handler = { [weak model] scan in model?.handle(scan, cardOpen: model?.item != nil) ?? .ignored }
        }
        .onDisappear { if torchOn { _ = Torch.set(false); torchOn = false } }
        .task {
            guard !started else { return }
            started = true
            await model.start()
            await feedFixture()
        }
        .task(id: model.noticeSeq) { await autoDismissNotice() }
    }

    /// 顶栏右边：对上账了写「✓ 已同步」，没连上写「没网」
    private var statusCount: Int? {
        switch model.phase {
        case .ready, .submitting, .stale: 0
        default: nil
        }
    }

    /// 返回：正在存的时候不理（等结果，问句不能没人看）；商品卡开着先关卡（没存的数作废）；等扫码时还有没数的先看 12b；否则离开
    private func back() {
        if model.phase == .submitting { return }
        if model.item != nil, !model.busy {
            model.close()
        } else if model.phase == .ready, (model.progress?.remaining ?? 0) > 0 {
            model.showList = true
        } else {
            dismiss()
        }
    }

    // MARK: 对账中 / 没网

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在跟服务器对账…").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("count.connecting")
    }

    private var offline: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 44, weight: .semibold)).foregroundStyle(Tokens.Palette.ink2)
                .accessibilityHidden(true)
            Text(CountModel.offlineText).font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
                .accessibilityIdentifier("count.offline")
            Text("盘点要对着服务器上的账数，连上网再来；卖出、进货不受影响")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            PrimaryButton("再试一次", systemImage: "arrow.clockwise", style: .dark, size: .medium) {
                Task { await model.start() }
            }
            .accessibilityIdentifier("count.retry")
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 进度

    private var progressHeader: some View {
        let done = model.progress?.counted ?? 0, left = model.progress?.remaining ?? 0
        let total = max(1, done + left)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("已经数了 \(done) 种").font(.system(size: 24, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .accessibilityIdentifier("count.done")
                Spacer(minLength: 8)
                Button { model.showList = true } label: {
                    Text("还有 \(left) 种").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                        .frame(minHeight: 44)
                }
                .disabled(left == 0)
                .accessibilityIdentifier("count.left")
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.Palette.line)
                    Capsule().fill(Tokens.Palette.ink).frame(width: g.size.width * CGFloat(done) / CGFloat(total))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "barcode.viewfinder").font(.system(size: 40, weight: .semibold)).foregroundStyle(Tokens.Palette.ink)
                .accessibilityHidden(true)
            Text("扫一个商品，数一数货架上有几个").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("没扫的商品按账上算，不会改").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("count.empty")
    }

    // MARK: 12a

    private var card: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    progressHeader
                    productCard
                    if let it = model.item {
                        Text("货架上实际数了几\(it.unit)").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                            .accessibilityIdentifier("count.prompt")
                    }
                    inputBox
                    if let h = model.hint {
                        Banner(kind: .alert, text: h, systemImage: "exclamationmark.triangle")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("count.hint")
                    }
                    Keypad(showsDot: false) { model.key($0) }
                        .disabled(model.phase != .ready)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Tokens.Palette.paper)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var productCard: some View {
        if let it = model.item {
            HStack(spacing: 14) {
                Thumb(initial: String(it.product.name.prefix(1)), ref: Thumb.ref(it.product), size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.product.name).font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("count.name")
                    Text("账上还有").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                }
                Spacer(minLength: 8)
                Text("\(it.stockQty)").font(TypeScale.total).foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityIdentifier("count.book")
            }
            .padding(16)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(it.product.name)，账上还有 \(it.stockQty) \(it.unit)")
            .accessibilityIdentifier("count.card")
        }
    }

    private var inputBox: some View {
        HStack(spacing: 2) {
            Text(model.text).font(TypeScale.price).foregroundStyle(Tokens.Palette.ink)
            Rectangle().fill(Tokens.Palette.ink).frame(width: 2, height: 40).accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 76)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
        .padding(4)
        .background(Tokens.Palette.line.opacity(0.6), in: RoundedRectangle(cornerRadius: Tokens.Radius.card + 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实际数了")
        .accessibilityValue(model.text.isEmpty ? "还没填" : model.text)
        .accessibilityIdentifier("count.input")
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            PrimaryButton("没错", style: .ghost) { Task { await model.confirmBook() } }
                .frame(maxWidth: 150)
                .disabled(!model.canConfirmBook)
                .accessibilityIdentifier("count.same")
            PrimaryButton(model.phase == .submitting ? "正在存…" : "存好，扫下一个", systemImage: "barcode.viewfinder", style: .dark) {
                Task { await model.save() }
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier("count.save")
        }
    }

    private func noticeBanner(_ n: CountModel.Notice) -> some View {
        Banner(kind: n.isError ? .alert : .soft, text: n.text,
               systemImage: n.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .padding(.horizontal, 20)
            .onTapGesture { model.dismissNotice(seq: model.noticeSeq) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("count.notice")
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

    private func feedFixture() async {
        guard !fedFixture else { return }
        fedFixture = true
        #if DEBUG
        if let scanner = fixture.scanner { await scanner.run(into: hub) }
        #endif
    }
}

/// 12b 还有 M 种没数：每行「去数」直接填；底下「接着扫码数」「先到这里，结束盘点」
struct CountListView: View {
    @Environment(\.dismiss) private var dismiss
    let model: CountModel
    let onFinish: () -> Void

    var body: some View {
        let items = model.progress?.uncounted ?? []
        VStack(spacing: 0) {
            ModeBar(title: model.title, pendingCount: 0, onBack: { dismiss() })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("还有 \(items.count) 种没数").font(.system(size: 28, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                        .accessibilityIdentifier("countList.title")
                    Text("没数的按账上算，不算少。可以接着扫，也可以点「去数」")
                        .font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4).padding(.bottom, 8)
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        row(it, index: i)
                        Divider().overlay(Tokens.Palette.line)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            VStack(spacing: 10) {
                PrimaryButton("接着扫码数", systemImage: "barcode.viewfinder", style: .dark) { dismiss() }
                    .accessibilityIdentifier("countList.scan")
                PrimaryButton("先到这里，结束盘点", style: .ghost, size: .small) { onFinish() }
                    .accessibilityIdentifier("countList.finish")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.countList")
    }

    private func row(_ it: CountItem, index: Int) -> some View {
        HStack(spacing: 12) {
            Thumb(initial: String(it.product.name.prefix(1)), ref: Thumb.ref(it.product), size: 52, fill: Tokens.Palette.line)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.product.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("账上 \(it.stockQty) \(it.unit)").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("countList.\(index)")
            Spacer(minLength: 8)
            Button { model.open(it) } label: {
                Text("去数").font(.system(size: 22, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                    .frame(minWidth: 96, minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .accessibilityLabel("去数 \(it.product.name)")
            .accessibilityIdentifier("countList.\(index).go")
        }
        .padding(.vertical, 12)
    }
}
