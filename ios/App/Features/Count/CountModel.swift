import Foundation
import Observation
import ShopCore

/// 盘点交账的通道：真机上先停定时同步、排空 outbox、拉到底，再单独交 `count`（`SyncEngine.drainForOnline / submitOnline`），
/// 测试里换成假的（`-uiCountOutcome`）
struct CountBackend: Sendable {
    var drain: @Sendable () async throws -> Void
    var submit: @Sendable (Op) async throws -> OnlineOutcome
    /// 排空成功后没走到 submit（版本变了先问人、商品不在了……）：让停掉的定时同步接着跑
    var finish: @Sendable () async -> Void = {}
}

/// 12a 盘点 / 12b 还有几种没数。**必须联网**（§5.6 第 1 条）：进页面先排空一次（连不上就「要联网才能盘点」），
/// 每存一个都先把本机的账传完、拉到底，账面版本还是人数货时看到的那一版才交；变了（另一台手机这期间卖了）
/// 先问「账上现在是 N 个，你数的还对吗」，人确认后带新版本交。交上去被拒 stale 也一样问。
/// 差额、金额、批次全由服务器算；没扫的商品不动。
@MainActor @Observable
final class CountModel {
    enum Phase: Equatable {
        /// 进页面时排空、对账
        case connecting
        /// 没连上：「要联网才能盘点」
        case offline
        case ready
        case submitting
        /// 别的手机刚又记了账：账上现在是 `stockQty`，问「你数的还对吗」
        case stale(stockQty: Int64, stockVer: Int64)
    }

    let db: LocalDB
    let backend: CountBackend?
    private let clock: () -> Date

    private(set) var phase: Phase = .connecting
    private(set) var progress: CountProgress?
    /// 12a 正在数的商品；nil = 等扫码
    private(set) var item: CountItem?
    /// 框里的数（只有数字）
    private(set) var text = ""
    /// 人数货时看到的账面版本（stale 后换成人确认过的那一版）
    private var seenVer: Int64 = 0
    /// 上一次交到一半没连上（不知道服务器记没记上）的 op：同一个商品、同一个数再存时原样重交，不换 id
    /// （`submitOnline` 幂等；换新 op 而第一次其实记上了，会把自己刚交的结果当成别的手机的账来问，PR #72 Opus 建议 1）
    private var unsure: (op: Op, productId: UUID, counted: Int64)?
    /// 这次交成功的（拉取还没带回流水时进度也算上）
    private var countedNow: Set<UUID> = []
    /// 页面上的提示（「红牛 250ml 存好了」「这个码没登记过」……）
    private(set) var notice: Notice?
    private(set) var noticeSeq = 0
    /// 12b 开着
    var showList = false
    #if DEBUG
    /// `-uiCountStaleOnce`：第一次交时带旧一版的版本（联调对着真服务器演 stale）
    var debugStaleOnce = ProcessInfo.processInfo.arguments.contains("-uiCountStaleOnce")
    #endif
    /// 存好一个（首页、设置页的数重取）
    var onSaved: (() -> Void)?
    /// 交完一个、关掉商品卡：扫码层清资格（还在画面里的要拿开再扫）
    var onCardClosed: (() -> Void)?

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    static let offlineText = "要联网才能盘点"

    init(db: LocalDB, backend: CountBackend?, clock: @escaping () -> Date) {
        self.db = db
        self.backend = backend
        self.clock = clock
    }

    var today: CalendarDate { LocalDB.shanghaiDay(clock()) }
    var title: String { "盘点 \(today.month)月" }
    var counted: Int64? { CountRule.counted(text) }
    var hint: String? {
        guard let item, let c = counted else { return nil }
        return CountRule.hint(counted: c, book: item.stockQty, unit: item.unit)
    }
    var canSave: Bool { item != nil && counted != nil && phase == .ready }
    var canConfirmBook: Bool { item.map { CountRule.canConfirmBook($0.stockQty) } ?? false && phase == .ready }
    var busy: Bool { phase == .submitting || phase == .connecting }

    // MARK: 进页面

    /// 先把本机的账传完、拉到底（提交前先传完本机 outbox）；连不上就停在「要联网才能盘点」
    func start() async {
        phase = .connecting
        guard let backend else { phase = .offline; return }
        do {
            try await backend.drain()
            await backend.finish()
            await reload()
            phase = .ready
        } catch {
            phase = .offline
        }
    }

    func reload() async {
        let db = db, today = today, done = countedNow
        progress = await Task.detached { try? db.countProgress(today: today, alsoCounted: done) }.value
    }

    // MARK: 扫码 / 去数

    /// 扫到一个码（相机、扫码枪、手输）。等对账、交账时不收；商品卡开着时相机的码不收（同进货页），扫码枪、手输换商品
    func handle(_ scan: Scan, cardOpen: Bool) -> ScanOutcome {
        guard phase == .ready else { return .ignored }
        if scan.source == .camera, cardOpen { return .ignored }
        do {
            guard let it = try db.countItem(barcode: scan.code) else {
                show("这个码没登记过（\(scan.code)），先在卖出或进货里登记", error: true)
                return .unknown
            }
            guard !it.product.needsReview else {
                show("「\(it.product.name)」还没补全，先到「商品」里补全", error: true)
                return .unknown
            }
            open(it)
            return .known
        } catch {
            show("没认出来：\(error.localizedDescription)", error: true)
            return .unknown
        }
    }

    /// 12a 开始数一个商品（扫到的，或 12b 点「去数」）
    func open(_ it: CountItem) {
        guard phase == .ready else { return }
        item = it
        seenVer = it.stockVer
        text = ""
        notice = nil
        showList = false
    }

    func close() {
        item = nil
        text = ""
        onCardClosed?()
    }

    func key(_ k: Keypad.Key) {
        guard phase == .ready, item != nil else { return }
        switch k {
        case .digit(let d): text = CountRule.append(text, digit: Character(String(d)))
        case .delete: text = CountRule.backspace(text)
        case .dot: break   // 键盘上没有小数点
        }
    }

    // MARK: 存

    /// 「存好，扫下一个」
    func save() async {
        guard canSave, let c = counted else { return }
        await submit(counted: c, expectedVer: seenVer)
    }

    /// 「没错」：数的和账上一样（也记一条，进度靠它）
    func confirmBook() async {
        guard canConfirmBook, let it = item else { return }
        text = String(it.stockQty)
        await submit(counted: it.stockQty, expectedVer: seenVer)
    }

    /// stale 后「对，就是 N 个」：带服务器现在的版本交
    func confirmStale() async {
        guard case .stale(_, let v) = phase, let c = counted else { return }
        phase = .ready
        await submit(counted: c, expectedVer: v)
    }

    /// stale 后「再数一下」：账上的数换成现在的，回去改
    func recount() {
        guard case .stale = phase else { return }
        phase = .ready
    }

    private func submit(counted: Int64, expectedVer: Int64) async {
        guard let backend, let it = item else { phase = .offline; return }
        phase = .submitting
        notice = nil
        let db = db, now = clock(), pid = it.id
        var needsFinish = false
        do {
            // 1. 先把本机的账传完、拉到底；之后本机的基线就是服务器现在的
            try await backend.drain()
            needsFinish = true
            let retry = unsure.flatMap { $0.productId == pid && $0.counted == counted ? $0.op : nil }
            unsure = nil
            let prepared: CountPrepared
            if let retry { prepared = .submit(retry) } else {
                prepared = try await Task.detached { try db.countOp(productId: pid, counted: counted, expectedVer: expectedVer, at: now) }.value
            }
            switch prepared {
            case .gone:
                item = nil; phase = .ready
                show("这个商品不在了", error: true)
            case .stale(let q, let v):
                // 2. 排空拉到了别的手机的新账：不交，先问
                staled(q, v)
            case .submit(var op):
                #if DEBUG
                // 联调（S26LiveUITests）：第一次故意带旧一版的账面版本，让真服务器回 stale
                if retry == nil, debugStaleOnce, let p = op.payload as? CountPayload, p.baseVer > 0 {
                    debugStaleOnce = false
                    op = Op(occurredAt: now, payload: try CountPayload(entryId: UUID(), productId: p.productId, countedQty: p.countedQty,
                                                                      baseQty: p.baseQty, baseVer: p.baseVer - 1))
                }
                #endif
                // 3. 单独交（submit 交完自己让同步接着跑）。没连上、不知道成没成：记下这个 op，下次原样重交
                needsFinish = false
                let outcome: OnlineOutcome
                do { outcome = try await backend.submit(op) } catch {
                    if !(error is OnlineSubmitError), !(error is SyncError) { unsure = (op, pid, counted) }
                    throw error
                }
                switch outcome {
                case .applied, .held: await saved(it)
                case .stale(let q, let v): staled(q, v)
                case .rejected(let code):
                    phase = .ready
                    show(Self.rejectMessage(code), error: true)
                }
            }
        } catch OnlineSubmitError.outboxNotDrained {
            phase = .ready; show("还有账没传上去，等传完再存（看看网）", error: true)
        } catch OnlineSubmitError.deletePending {
            phase = .ready; show("账号在注销中，不能记账", error: true)
        } catch OnlineSubmitError.resynced {
            phase = .ready
            await refreshItem()
            show("刚跟服务器重新对了一次账，看一眼账上的数再存", error: true)
        } catch is SyncError {
            phase = .ready   // 被踢了：页面会回到登录（25b / 25f）
        } catch {
            phase = .ready; show("\(Self.offlineText)，没存上。连上网再点一次", error: true)
        }
        if needsFinish { await backend.finish() }
    }

    private func staled(_ q: Int64, _ v: Int64) {
        guard let it = item else { return }
        item = CountItem(product: it.product, stockQty: q, stockVer: v)
        seenVer = v
        phase = .stale(stockQty: q, stockVer: v)
    }

    private func saved(_ it: CountItem) async {
        countedNow.insert(it.id)
        item = nil
        text = ""
        phase = .ready
        show("「\(it.product.name)」存好了，扫下一个", error: false)
        await reload()
        onSaved?()
        onCardClosed?()
    }

    private func refreshItem() async {
        guard let it = item else { return }
        let db = db, id = it.id
        if let fresh = await Task.detached(operation: { try? db.countItem(id) }).value {
            item = fresh
            seenVer = fresh.stockVer
        }
    }

    func show(_ text: String, error: Bool) {
        notice = Notice(text: text, isError: error)
        noticeSeq += 1
    }

    func dismissNotice(seq: Int) { if seq == noticeSeq { notice = nil } }

    static func rejectMessage(_ code: String?) -> String {
        switch code {
        case "forbidden": "这台手机不能盘点"
        default: "服务器没收（\(code ?? "原因不明")），回头再试"
        }
    }

    /// 「账上现在是 N 罐，你数的还对吗」
    var staleQuestion: String? {
        guard case .stale(let q, _) = phase, let it = item else { return nil }
        return CountRule.staleQuestion(stockQty: q, unit: it.unit)
    }
}

#if DEBUG
extension CountBackend {
    /// UI 测试的假通道（`-uiCountOutcome applied|stale|offline|lost`）：不连服务器。
    /// `offline` 排空就失败；`stale` 第一次交时回「账上现在比看到的少 1 个」、确认后成功；
    /// 成功时把这样商品在本机改成数到的数（像服务器的拉取带回来那样）
    static func fixture(outcome: String, db: LocalDB) -> CountBackend {
        final class Count: @unchecked Sendable { var n = 0; var first: UUID? }
        let count = Count()
        return CountBackend(
            drain: { if outcome == "offline" { throw URLError(.notConnectedToInternet) } },
            submit: { op in
                count.n += 1
                guard let p = op.payload as? CountPayload else { return .rejected(code: "invalid") }
                // `lost`：第一次服务器记上了、回包丢了；同一个 op 重交拿回第一次的结果，换了新 op 就按新版本比对（会回 stale）
                if outcome == "lost" {
                    if count.n == 1 {
                        count.first = op.id
                        try await Task.detached { try Self.setBook(db, p.productId, qty: p.countedQty, ver: p.baseVer + 1) }.value
                        throw URLError(.networkConnectionLost)
                    }
                    if op.id == count.first { return .applied }
                    return .stale(stockQty: p.countedQty, stockVer: p.baseVer + 1)
                }
                if outcome == "stale", count.n == 1 {
                    try await Task.detached { try Self.setBook(db, p.productId, qty: p.baseQty - 1, ver: p.baseVer + 1) }.value
                    return .stale(stockQty: p.baseQty - 1, stockVer: p.baseVer + 1)
                }
                try await Task.detached { try Self.setBook(db, p.productId, qty: p.countedQty, ver: p.baseVer + 1) }.value
                return .applied
            })
    }

    nonisolated private static func setBook(_ db: LocalDB, _ id: UUID, qty: Int64, ver: Int64) throws {
        guard let prod = try db.product(id), let v = try db.productPrivate(id) else { return }
        let product: [String: Any] = [
            "id": prod.id.uuidString.lowercased(), "name": prod.name, "base_unit": prod.baseUnit, "price_fen": prod.priceFen.raw,
            "needs_review": prod.needsReview, "track_expiry": prod.trackExpiry, "image_ver": prod.imageVer, "archived": prod.archived,
            "rev": 1,
            "private": ["stock_qty": qty, "stock_value_fen": v.costKnown ? max(0, qty) * (v.lastCostFen?.raw ?? 0) : 0,
                        "last_cost_fen": v.lastCostFen.map { $0.raw as Any } ?? NSNull(), "cost_known": v.costKnown,
                        "stock_ver": ver, "low_at": v.lowAt.map { $0 as Any } ?? NSNull(), "expiry_warn_days": v.expiryWarnDays,
                        "shelf_life_months": v.shelfLifeMonths.map { $0 as Any } ?? NSNull()] as [String: Any]]
        let cur = try db.meta(.catalogCursor).flatMap { Int($0) } ?? 0
        let led = try db.meta(.ledgerCursor).flatMap { Int($0) } ?? 0
        let obj: [String: Any] = [
            "results": [], "changes": ["products": [product], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": cur, "ledger": led], "has_more": ["catalog": false, "ledger": false], "total_products": 0,
            "server_time": Op.formatTimestamp(Date()), "epoch": (try db.meta(.serverEpoch)) ?? UUID().uuidString, "min_build": 0,
            "device": ["role": "family", "label": "测试", "revoked": false], "store": ["name": "测试"]]
        try db.applySyncResponse(try SyncResponse.decode(try JSONSerialization.data(withJSONObject: obj)), sent: nil)
    }
}
#endif

extension AppModel {
    /// 盘点交账的通道（S26）：先停掉定时同步、等在途的那趟跑完（不和它同时写本地库），排空 outbox、拉到底，
    /// 再单独交 `count`；交完让同步接着跑。没有网络服务（夹具）时返回 nil，页面按没网处理。
    /// Debug 的 `-uiCountOutcome applied|stale|offline` 换成假通道（UI 测试用）
    func makeCountBackend() -> CountBackend? {
        #if DEBUG
        if let o = UIFixture.value(for: "-uiCountOutcome", in: ProcessInfo.processInfo.arguments) {
            return CountBackend.fixture(outcome: o, db: db)
        }
        #endif
        guard let sync else { return nil }
        let db = db, build = services?.build ?? 0, transport = sync.transportForDrain
        let engine = SyncEngine(db: db, appBuild: build, transport: transport)
        return CountBackend(
            drain: { [weak self] in
                await self?.pauseSyncForOnline()
                do { try await Task.detached(priority: .userInitiated) { try engine.drainForOnline() }.value } catch {
                    await self?.resumeAfterOnline(error); throw error
                }
            },
            submit: { [weak self] op in
                do {
                    let r = try await Task.detached(priority: .userInitiated) { try engine.submitOnline(op) }.value
                    await self?.resumeAfterOnline(nil)
                    return r
                } catch { await self?.resumeAfterOnline(error); throw error }
            },
            finish: { [weak self] in await self?.resumeAfterOnline(nil) })
    }

    func pauseSyncForOnline() async {
        sync?.stop()
        await sync?.idle()
    }

    /// 交完（或交不上）：被踢了走 25b / 25f；否则同步接着跑
    func resumeAfterOnline(_ error: Error?) async {
        if case .revoked(let discard)? = error as? SyncError {
            if discard { sync?.onDiscard?() }
            if let recovery = sync?.recovery { _ = await recovery.run() }
            NotificationCenter.default.post(name: AppRoot.signedOut, object: db)
            return
        }
        sync?.start()
        sync?.kick()
    }

    /// 设置页「盘点」右边的「11月 数了 N 种」（本月有盘点流水的商品种数）
    func refreshCountSummary() {
        guard liveCount, capabilities.has(.count) else { return }
        let today = LocalDB.shanghaiDay(now)
        let n = (try? db.countProgress(today: today).counted) ?? 0
        figures.countSummary = "\(today.month)月 数了 \(n) 种"
    }
}
