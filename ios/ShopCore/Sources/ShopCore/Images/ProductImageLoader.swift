import Foundation
import os

/// 商品图下载器（S22c，plan-v2 §8 S22c；细节按 Fable 裁定 1–10）。
///
/// - 只从自家服务器取：`APIBase.url(bases.current, "/v1/images/<id>")?v=<image_ver>`，带 Bearer；不用下发的图片地址，
///   不跟 30x（`APIClient.NoRedirect`），不做「换默认地址重发」。
/// - 低优先级：独立 ephemeral 会话（不缓存、不存 cookie、每主机最多 2 个连接），并发 2，`URLSessionTask.lowPriority`；
///   单请求 20 秒、整体 30 秒。**同步在飞时不发新请求**（`syncBusy`；在飞的不取消）。图片请求和同步互不排队。
/// - 预取为主、按需插队：`prefetch` 把缺图的商品排到队尾，`request`（屏幕上缺图的 Thumb）插到队首。
///   预取的请求不走低数据模式（`allowsConstrainedNetworkAccess = false`），按需的照常。
/// - 失败（裁定 3）：404 → 这一版本进程内不再要，预取连续 5 个 404 停本轮；403 → 本会话停用；401 → 等下次同步成功；
///   5xx / 超时 / 传输错误 → 单张退避 1 / 5 / 30 分钟，连续 3 次失败整队暂停 60 秒起倍增到 30 分钟，成功或回前台清零。
///   不是 image/jpeg、大于 256 KB、解不出来、ETag 不是请求的版本：都不落盘。负缓存只在内存。
/// - 会话代数 `generation`：关开关、换会话、epoch 重建都 +1；迟到的响应代数不对就丢掉，不写盘。
/// - 不进 outbox、不改库表；日志不打商品名和令牌。
public actor ProductImageLoader {
    public struct Policy: Sendable {
        public var concurrency = 2
        public var requestTimeout: TimeInterval = 20
        public var resourceTimeout: TimeInterval = 30
        public var maxBytes = 256 * 1024
        /// 单张退避（秒）：第 1、2、3 次及以后
        public var itemBackoff: [TimeInterval] = [60, 300, 1800]
        public var queueFailureLimit = 3
        public var queuePauseBase: TimeInterval = 60
        public var queuePauseMax: TimeInterval = 1800
        public var prefetch404Limit = 5
        /// 同步在飞 / 整队暂停时多久看一次
        public var pollInterval: Duration = .milliseconds(100)
        public init() {}
    }

    public enum Event: Sendable, Equatable {
        /// 落盘了
        case stored(ImageKey)
        /// 服务器说没图（404）或内容不合格：显示首字
        case missing(ImageKey)
    }

    enum Origin: Sendable { case prefetch, onDemand }
    struct Item: Sendable { let key: ImageKey; var origin: Origin }

    /// 一次请求的结果（测试和日志看）
    enum Outcome: Sendable {
        case response(status: Int, data: Data, contentType: String?, etag: String?)
        case transport
        /// 低数据模式拦下了预取的请求（`allowsConstrainedNetworkAccess = false`）：不算失败，停本轮预取
        case constrained
        case cancelled
    }

    public nonisolated let disk: ProductImageDisk
    private let base: @Sendable () -> URL
    private let token: @Sendable () -> String?
    private let syncBusy: @Sendable () -> Bool
    private let validate: @Sendable (Data) -> Bool
    private let onEvent: @Sendable (Event) -> Void
    private let now: @Sendable () -> Date
    let policy: Policy
    nonisolated let session: URLSession

    public private(set) var enabled: Bool
    public private(set) var generation = 0
    private var queue: [Item] = []
    private var inFlightKeys: Set<ImageKey> = []
    private var workers: [Int: Task<Void, Never>] = [:]
    private var nextWorker = 0
    private var missing: Set<ImageKey> = []
    private var backoff: [ImageKey: (fails: Int, until: Date)] = [:]
    private var consecutiveFailures = 0
    private var pauseLevel = 0
    private var pausedUntil: Date?
    private var prefetch404Run = 0
    /// 403：本会话不再请求
    public private(set) var forbidden = false
    /// 401：等下次同步成功（`prefetch`）再请求，不触发登出
    public private(set) var unauthorized = false
    /// 进后台：停（不用 background URLSession / BGTask）
    public private(set) var suspended = false

    // 测试看
    public private(set) var requestsSent = 0
    public private(set) var maxConcurrent = 0
    private var concurrent = 0

    static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "images")

    public init(disk: ProductImageDisk, enabled: Bool, policy: Policy = Policy(),
                configuration: URLSessionConfiguration = .ephemeral,
                base: @escaping @Sendable () -> URL, token: @escaping @Sendable () -> String?,
                syncBusy: @escaping @Sendable () -> Bool = { false },
                validate: @escaping @Sendable (Data) -> Bool = ProductImageLoader.looksLikeJPEG,
                now: @escaping @Sendable () -> Date = { Date() },
                onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.disk = disk
        self.enabled = enabled
        self.policy = policy
        self.base = base
        self.token = token
        self.syncBusy = syncBusy
        self.validate = validate
        self.now = now
        self.onEvent = onEvent
        self.session = Self.makeSession(configuration, policy: policy)
    }

    /// 独立的 ephemeral 会话：不缓存、不存 cookie、每主机最多 2 个连接、不跟重定向
    static func makeSession(_ c: URLSessionConfiguration, policy: Policy) -> URLSession {
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpMaximumConnectionsPerHost = policy.concurrency
        c.timeoutIntervalForRequest = policy.requestTimeout
        c.timeoutIntervalForResource = policy.resourceTimeout
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: APIClient.NoRedirect.shared, delegateQueue: nil)
    }

    /// JPEG 文件头（ShopCore 不依赖 UIKit；App 传进来的校验另外真解一遍）
    public static let looksLikeJPEG: @Sendable (Data) -> Bool = { d in d.count > 3 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 }

    /// 请求地址：当前服务器地址 + `/v1/images/<id>?v=<ver>`
    public nonisolated static func url(base: URL, key: ImageKey) -> URL {
        var c = URLComponents(url: APIBase.url(base, path: "/v1/images/\(key.productId.uuidString.lowercased())"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "v", value: String(key.ver))]
        return c.url!
    }

    // MARK: - 对外

    /// 启动时：删不是当前店的子目录
    public func start() { disk.removeOtherStores() }

    /// 同步成功（商品流已拉完）、或开关 false→true 之后：把缺图的全排上（不设上限），清掉不在商品表里的文件。
    /// 也是 401 之后恢复的时机（同步成功说明令牌还认）
    public func prefetch(_ wants: [ImageKey]) {
        unauthorized = false
        guard enabled, !forbidden else { return }
        prefetch404Run = 0
        disk.prune(keeping: Set(wants.map(\.productId)))
        let present = Set(disk.keys())
        for k in wants where !present.contains(k) && eligible(k) && !queue.contains(where: { $0.key == k }) {
            queue.append(Item(key: k, origin: .prefetch))
        }
        pump()
    }

    /// 屏幕上的 Thumb 缺这张图：插到队首
    public func request(_ k: ImageKey) {
        guard enabled, !forbidden, k.ver > 0, eligible(k), !disk.has(k) else { return }
        queue.removeAll { $0.key == k }
        queue.insert(Item(key: k, origin: .onDemand), at: 0)
        pump()
    }

    /// 已经确定没图（404 / 不合格）的版本
    public func isMissing(_ k: ImageKey) -> Bool { missing.contains(k) }

    /// 开关（T11）：false 当场取消在飞请求、删整个目录；true 只是放开，调用方接着 `prefetch`
    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { reset() }
    }

    /// 会话变化（退出、被踢、换身份、换店、epoch 重建）：取消请求、删整目录，代数 +1
    public func reset() {
        generation += 1
        for t in workers.values { t.cancel() }
        workers.removeAll()
        queue.removeAll()
        inFlightKeys.removeAll()
        missing.removeAll()
        backoff.removeAll()
        consecutiveFailures = 0; pauseLevel = 0; pausedUntil = nil
        prefetch404Run = 0
        concurrent = 0
        disk.removeAll()
    }

    /// 这个会话结束：之后什么都不做
    public func shutdown() {
        enabled = false
        reset()
    }

    /// 进后台：取消在飞的（放回队首），停
    public func suspend() {
        guard !suspended else { return }
        suspended = true
        generation += 1   // 在飞的回来了也不算
        for t in workers.values { t.cancel() }
        workers.removeAll()
        for k in inFlightKeys where !queue.contains(where: { $0.key == k }) { queue.insert(Item(key: k, origin: .prefetch), at: 0) }
        inFlightKeys.removeAll()
        concurrent = 0
    }

    /// 回前台：退避和整队暂停清零，接着下
    public func resume() {
        suspended = false
        backoff.removeAll()
        consecutiveFailures = 0; pauseLevel = 0; pausedUntil = nil
        pump()
    }

    /// 留给 S22d-iOS：拍照上传成功后直接把这张图放进缓存
    public func prime(_ data: Data, productId: UUID, ver: Int) {
        let k = ImageKey(productId, ver)
        guard enabled, ver > 0, data.count <= policy.maxBytes, validate(data) else { return }
        do { try disk.write(data, for: k); missing.remove(k); onEvent(.stored(k)) } catch {
            Self.logger.notice("图片写盘失败：\(String(describing: error), privacy: .public)")
        }
    }

    public var queuedCount: Int { queue.count }
    /// 没有在跑的工作（队列空了，或者暂时不能跑：关着、401 / 403、进后台）
    public var idle: Bool { workers.isEmpty && (queue.isEmpty || !runnable) }

    // MARK: - 内部

    private func eligible(_ k: ImageKey) -> Bool {
        if missing.contains(k) || inFlightKeys.contains(k) { return false }
        if let b = backoff[k], b.until > now() { return false }
        return true
    }

    private var runnable: Bool { enabled && !forbidden && !unauthorized && !suspended }

    private func pump() {
        guard runnable else { return }
        while workers.count < policy.concurrency, workers.count < queue.count + inFlightKeys.count {
            let id = nextWorker
            nextWorker += 1
            let gen = generation
            workers[id] = Task(priority: .utility) { await self.work(id: id, generation: gen) }
        }
    }

    private func work(id: Int, generation gen: Int) async {
        while !Task.isCancelled, gen == generation, runnable {
            guard queue.contains(where: { eligible($0.key) }) else {
                // 剩下的都在退避或已知没图：丢掉，下一轮预取 / 屏幕上要的时候再排
                queue.removeAll { !eligible($0.key) }
                break
            }
            // 同步在飞、整队暂停：先等（不发新请求，不占同步）
            if syncBusy() || (pausedUntil.map { $0 > now() } ?? false) {
                try? await Task.sleep(for: policy.pollInterval)
                continue
            }
            guard let i = queue.firstIndex(where: { eligible($0.key) }) else { continue }
            let item = queue.remove(at: i)
            guard let tok = token() else { unauthorized = true; queue.insert(item, at: 0); break }
            await fetch(item, token: tok, generation: gen)
        }
        if gen == generation { workers[id] = nil }
    }

    private func fetch(_ item: Item, token tok: String, generation gen: Int) async {
        let k = item.key
        var req = URLRequest(url: Self.url(base: base(), key: k), timeoutInterval: policy.requestTimeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        req.allowsConstrainedNetworkAccess = item.origin == .onDemand
        req.cachePolicy = .reloadIgnoringLocalCacheData
        inFlightKeys.insert(k)
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        requestsSent += 1
        let outcome = await Self.perform(session, req)
        guard gen == generation else { return }   // 迟到的（换会话 / 关开关 / 进后台之后回来的）不写盘
        concurrent -= 1
        inFlightKeys.remove(k)
        handle(outcome, item)
    }

    private func handle(_ outcome: Outcome, _ item: Item) {
        let k = item.key
        switch outcome {
        case .cancelled:
            return
        case .constrained:
            Self.logger.notice("低数据模式：停本轮预取")
            queue.removeAll { $0.origin == .prefetch }
        case .transport:
            failed(k, why: "transport")
        case let .response(status, data, type, etag):
            switch status {
            case 200:
                let typeOK = (type ?? "").lowercased().hasPrefix("image/jpeg")
                let etagOK = Self.etagVersion(etag) == k.ver
                guard typeOK, etagOK, data.count <= policy.maxBytes, validate(data) else {
                    Self.logger.notice("图片不合格，不落盘：\(k.description, privacy: .public) type=\(type ?? "-", privacy: .public) etag=\(etag ?? "-", privacy: .public) bytes=\(data.count)")
                    missing.insert(k)
                    onEvent(.missing(k))
                    return
                }
                do {
                    try disk.write(data, for: k)
                } catch {
                    Self.logger.notice("图片写盘失败：\(String(describing: error), privacy: .public)")
                    return
                }
                backoff[k] = nil
                consecutiveFailures = 0; pauseLevel = 0; pausedUntil = nil
                onEvent(.stored(k))
            case 404:
                missing.insert(k)
                consecutiveFailures = 0
                onEvent(.missing(k))
                if item.origin == .prefetch {
                    prefetch404Run += 1
                    if prefetch404Run >= policy.prefetch404Limit {
                        Self.logger.notice("预取连续 \(self.prefetch404Run) 个 404，停本轮")
                        queue.removeAll { $0.origin == .prefetch }
                    }
                }
            case 403:
                Self.logger.notice("图片 403：本会话不再请求")
                forbidden = true
                queue.removeAll()
            case 401:
                Self.logger.notice("图片 401：等下次同步成功")
                unauthorized = true
                queue.insert(item, at: 0)
            default:
                failed(k, why: "status \(status)")
            }
        }
        if item.origin == .prefetch, case .response(200, _, _, _) = outcome { prefetch404Run = 0 }
    }

    private func failed(_ k: ImageKey, why: String) {
        let fails = (backoff[k]?.fails ?? 0) + 1
        let wait = policy.itemBackoff[min(fails, policy.itemBackoff.count) - 1]
        backoff[k] = (fails, now().addingTimeInterval(wait))
        consecutiveFailures += 1
        Self.logger.notice("图片没下成（\(why, privacy: .public)），\(Int(wait)) 秒后再试")
        if consecutiveFailures >= policy.queueFailureLimit {
            let pause = min(policy.queuePauseBase * pow(2, Double(pauseLevel)), policy.queuePauseMax)
            pauseLevel += 1
            consecutiveFailures = 0
            pausedUntil = now().addingTimeInterval(pause)
            Self.logger.notice("连续失败，整队暂停 \(Int(pause)) 秒")
        }
    }

    /// `"3"` / `W/"3"` → 3
    static func etagVersion(_ etag: String?) -> Int? {
        guard var s = etag?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("W/") { s.removeFirst(2) }
        return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ t: URLSessionDataTask) { lock.withLock { task = t; if cancelled { t.cancel() } } }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }

    /// 发一个低优先级的请求；外面的 Task 取消了就取消请求
    static func perform(_ session: URLSession, _ req: URLRequest) async -> Outcome {
        let box = TaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                let t = session.dataTask(with: req) { data, resp, err in
                    if let e = err as? URLError, e.code == .cancelled { cont.resume(returning: .cancelled); return }
                    if let e = err as? URLError, e.networkUnavailableReason == .constrained { cont.resume(returning: .constrained); return }
                    guard err == nil, let http = resp as? HTTPURLResponse else { cont.resume(returning: .transport); return }
                    cont.resume(returning: .response(status: http.statusCode, data: data ?? Data(),
                                                     contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                                     etag: http.value(forHTTPHeaderField: "ETag")))
                }
                t.priority = URLSessionTask.lowPriority
                box.set(t)
                t.resume()
            }
        } onCancel: { box.cancel() }
    }
}
