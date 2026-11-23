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
/// - 被踢（revoked）、换 epoch（409）交 S22b，这里只记下、不重试。
@MainActor @Observable
final class SyncCoordinator {
    let db: LocalDB
    private let transport: SyncEngine.Transport
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
    /// S22b 要处理的：被踢 / 换 epoch
    private(set) var needsS22b: SyncError?
    /// 跑完一趟（成功或失败）的回调：AppModel 据此刷新首页的数
    var onFinish: (() -> Void)?
    /// 完成的趟数（测试看）
    private(set) var rounds = 0

    private var again = false
    private var timer: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    static let interval: Duration = .seconds(15)
    nonisolated static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "sync")

    init(db: LocalDB, build: Int, transport: @escaping SyncEngine.Transport) {
        self.db = db
        self.build = build
        self.transport = transport
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
        return c
    }

    /// Debug 的 `-uiOffline`：右上角显示「没网」，不听真实网络
    var simulatedOffline = false

    /// 开始定时（每 15 秒）和网络监听；会话结束时 `stop()`
    func start() {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.kick()
                try? await Task.sleep(for: Self.interval)
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
        guard needsS22b == nil else { return }
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
        } while again && needsS22b == nil
        running = false
    }

    private func once() async {
        let engine = SyncEngine(db: db, appBuild: build, transport: transport)
        let report: @Sendable (SyncProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        }
        let result = await Task.detached(priority: .utility) { () -> Result<SyncStatus, Error> in
            Result { try engine.sync(progress: report) }
        }.value
        rounds += 1
        switch result {
        case .success: lastError = nil
        case .failure(let e as SyncError): needsS22b = e
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
