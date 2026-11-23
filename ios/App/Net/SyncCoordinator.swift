import Foundation
import Network
import Observation
import os
import ShopCore

/// 同步的调度（S22a）：什么时候调 `SyncEngine`、在哪个线程调、结果怎么交给界面。
///
/// - 触发：写入之后（`AppModel.refreshRecent` / `kick()`）、回到前台、每 15 秒、网络恢复。同一时间只跑一趟，
///   跑的时候又来了触发就记一笔，跑完再来一趟。
/// - 线程：`SyncEngine` 的方法是同步阻塞的、会开写事务和压缩（PR #9 Fable 约束：不许在主线程），所以整趟放在
///   `Task.detached` 里；传输用 `APIClient.sync`（带令牌、不跟重定向），在后台线程上等它回来。
/// - 结果：每页回调一次进度（首次同步 29「194 / 312 样」），跑完把 `SyncStatus` 交回主线程给首页、设置、07a。
/// - S22b：每趟先用旧令牌传一遍恢复队列（`RecoveryRunner`，传不完不拦），再同步当前会话。换 epoch 由引擎握手处理；
///   被踢（revoked）：引擎已记下结果、会话已退役，这里停下并通知外面进 25b / 25f（演示店重置回登录页）。
@MainActor @Observable
final class SyncCoordinator {
    let db: LocalDB
    private let transport: SyncEngine.Transport
    /// 退出登录排空用：同一个传输（同一个令牌、同样的 Debug 断网模拟）
    var transportForDrain: SyncEngine.Transport { transport }
    private let build: Int
    private(set) var status: SyncStatus?
    private(set) var progress: SyncProgress?
    /// 首次同步的商品流拉到底了（之后才进首页开卖）
    private(set) var catalogDone: Bool
    private(set) var running = false
    /// 最近一趟失败的原因（没网、服务器错）；成功后清掉
    private(set) var lastError: String?
    /// 网络不通（NWPathMonitor）。首页右上角显示「↑ 没网」（25e）
    private(set) var offline = false
    /// 被踢了（会话已退役）：不再同步
    private(set) var signedOut: SyncError?
    /// 跑完一趟（成功或失败）的回调：AppModel 据此刷新首页的数
    var onFinish: (() -> Void)?
    /// 被踢 / 演示店重置：AppRoot 据此换到 25b / 25f 或登录页
    var onSignedOut: (() -> Void)?
    /// 恢复队列（以前的会话没传完的 op）：每趟同步之前先传一遍
    var recovery: RecoveryRunner?
    /// 完成的趟数（测试看）
    private(set) var rounds = 0

    private var again = false
    private var timer: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    static let interval: Duration = .seconds(15)
    /// 定时同步的间隔（正常 15 秒；测试缩短）
    let interval: Duration
    nonisolated static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "sync")
    /// 本进程一共建过几个（热修回归：一个会话只该有一个；测试和 Debug 探针看）
    private(set) static var created = 0

    init(db: LocalDB, build: Int, interval: Duration = SyncCoordinator.interval, transport: @escaping SyncEngine.Transport) {
        self.db = db
        self.build = build
        self.interval = interval
        Self.created += 1
        let stats = SyncStats.shared
        self.transport = { body in stats.sent(); return try transport(body) }
        let st = try? db.syncStatus()
        status = st
        catalogDone = st?.catalogDone ?? false
    }

    /// 正常启动：用 App 的 `APIClient` 和钥匙串里的令牌。`crash` 只在 Debug 的强杀验收里给（见 `CrashPoint`）
    static func live(db: LocalDB, services: AppServices, tokenRef: String, crash: CrashPoint? = nil,
                     args: [String] = ProcessInfo.processInfo.arguments) -> SyncCoordinator {
        let api = services.api, tokens = services.tokens
        #if DEBUG
        // XCUITest：-uiOffline 当作没网（请求一律连不上）；-uiSyncDelayMs 每个请求前等一会儿（看得见 29 的进度）
        let simulatedOffline = args.contains("-uiOffline")
        let delayMs = UIFixture.value(for: "-uiSyncDelayMs", in: args).flatMap(Int.init) ?? 0
        #else
        let simulatedOffline = false, delayMs = 0
        #endif
        let transport: SyncEngine.Transport = { body in
            if simulatedOffline { throw APIError.transport("模拟没网") }
            if delayMs > 0 { Thread.sleep(forTimeInterval: Double(delayMs) / 1000) }
            guard let token = try tokens.token(ref: tokenRef) else { throw APIError.server(status: 401, code: "unauthorized", lockedUntil: nil, retryAfterS: nil) }
            if crash == .afterSend {
                // 「请求发出后、响应到达前」：请求发出去，不等回包就整个进程退出
                Task.detached { _ = try? await api.sync(body: body, token: token) }
                Thread.sleep(forTimeInterval: 0.3)
                CrashPoint.die(.afterSend)
            }
            let r = try Blocking.wait { try await api.sync(body: body, token: token) }
            if crash == .beforeCommit, r.0 == 200 { CrashPoint.die(.beforeCommit) }  // 「响应到达后、本地提交前」
            return r
        }
        let c = SyncCoordinator(db: db, build: services.build, transport: transport)
        c.simulatedOffline = simulatedOffline
        c.recovery = RecoveryRunner.live(db: db, services: services, args: args)
        return c
    }

    /// Debug 的 `-uiOffline`：右上角显示「没网」，不听真实网络
    var simulatedOffline = false

    /// 开始定时（每 15 秒）和网络监听；会话结束时 `stop()`
    func start() {
        guard timer == nil else { return }
        let interval = interval
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 协调器没了就停，不留一个空转的定时任务（不在睡眠期间强持有 self）
                guard self?.kick() != nil else { return }
                try? await Task.sleep(for: interval)
            }
        }
        if simulatedOffline { offline = true; return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = self.offline
                self.offline = !up
                if up && wasOffline { self.kick() }  // 网络恢复
            }
        }
        m.start(queue: DispatchQueue(label: "yh.sync.path"))
        monitor = m
    }

    func stop() {
        timer?.cancel(); timer = nil
        monitor?.cancel(); monitor = nil
    }

    /// 来一趟。已经在跑就记下、跑完再来一趟（写入很快连着来时不会并发两趟）
    func kick() {
        guard signedOut == nil else { return }
        if running { again = true; return }
        running = true
        Task { await self.loop() }
    }

    /// 等当前这趟（和它之后补的那趟）跑完（测试用）
    func idle() async {
        while running { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func loop() async {
        repeat {
            again = false
            await once()
        } while again && signedOut == nil
        running = false
    }

    private func once() async {
        let engine = SyncEngine(db: db, appBuild: build, transport: transport)
        let report: @Sendable (SyncProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        }
        let recovery = recovery
        let result = await Task.detached(priority: .utility) { () -> Result<SyncStatus, Error> in
            // 恢复队列先传（兑码成功后第一次拉取之前也是这里），没网、传不完都不拦当前会话
            _ = recovery?.runBlocking()
            return Result { try engine.sync(progress: report) }
        }.value
        rounds += 1
        switch result {
        case .success: lastError = nil
        case .failure(let e as SyncError):
            signedOut = e
            stop()
            // 被踢：同一个旧令牌接着把剩下的补传（卖出带补传标记入账、别的待确认），然后才通知外面
            if case .revoked = e { _ = await recovery?.run() }
            refreshStatus()
            onFinish?()
            onSignedOut?()
            return
        case .failure(let e):
            lastError = String(describing: e)
            Self.logger.notice("同步没成功：\(String(describing: e), privacy: .public)")
        }
        refreshStatus()
        onFinish?()
    }

    private func apply(_ p: SyncProgress) {
        progress = p
        if p.catalogDone { catalogDone = true }
    }

    /// 从本地库重取同步状态（写入后不等同步也要马上看到待传笔数）
    func refreshStatus() {
        guard let st = try? db.syncStatus() else { return }
        status = st
        if st.catalogDone { catalogDone = true }
    }

    /// 首次同步进度：分子 = 本机商品数（强杀重开后接着数），分母 = 服务器给的总数
    var firstSyncFigures: (done: Int, total: Int?) {
        let done = (try? db.productCount()) ?? 0
        return (max(done, progress?.products ?? 0), progress?.totalProducts)
    }
}

/// 发出去的 `/v1/sync` 请求数（整个进程、所有协调器合计；热修回归测试和 Debug 探针看）
final class SyncStats: @unchecked Sendable {
    static let shared = SyncStats()
    private let lock = NSLock()
    private var n = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return n }
    func sent() { lock.lock(); n += 1; lock.unlock() }
}

/// 强杀验收（plan-v2 §8 S22a 崩溃注入）：Debug 包带 `-uiCrashAt <点>` 启动时，同步走到这个点就整个进程退出，
/// 和用户划掉 App 一样（不走任何收尾）。XCUITest 不带这个参数重开，看重启后不漏拉、不重复扣、服务器不重复记。
enum CrashPoint: String, Sendable {
    /// 请求发出后、响应到达前
    case afterSend
    /// 响应到达后、本地提交前
    case beforeCommit
    /// 本地提交中途（处理同步响应的事务里，`LocalDBFaultPoint.midSyncCommit`）
    case midCommit

    static func from(_ args: [String]) -> CrashPoint? {
        #if DEBUG
        return UIFixture.value(for: "-uiCrashAt", in: args).flatMap(CrashPoint.init(rawValue:))
        #else
        return nil
        #endif
    }

    static func die(_ p: CrashPoint) -> Never {
        SyncCoordinator.logger.notice("强杀验收：在 \(p.rawValue, privacy: .public) 退出")
        exit(9)
    }
}

/// 在后台线程上等一个 async 调用的结果（`SyncEngine.Transport` 是同步的）。不许在主线程用。
enum Blocking {
    final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

    static func wait<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread, "同步传输不许在主线程等")
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try box.value!.get()
    }
}
