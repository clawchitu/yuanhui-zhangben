import Foundation
import Testing
@testable import ShopCore

/// URLProtocol 桩：按处理函数回图片，记下每个请求、同时在飞的最大数（S22c，Fable 裁定 9）
final class ImageStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var contentType = "image/jpeg"
        var etag: String?
        var body = ImageFixtures.jpeg
        var delay: TimeInterval = 0
    }

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: @Sendable (URLRequest) -> Reply = { _ in Reply() }
        var requests: [URLRequest] = []
        var concurrent = 0
        var maxConcurrent = 0
        func reset() { lock.withLock { handler = { _ in Reply() }; requests = []; concurrent = 0; maxConcurrent = 0 } }
    }
    static let state = State()
    static var requests: [URLRequest] { state.lock.withLock { state.requests } }
    static var maxConcurrent: Int { state.lock.withLock { state.maxConcurrent } }
    static func respond(_ h: @escaping @Sendable (URLRequest) -> Reply) { state.lock.withLock { state.handler = h } }

    private var stopped = false
    private let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let s = Self.state
        let reply: Reply = s.lock.withLock {
            s.requests.append(request)
            s.concurrent += 1
            s.maxConcurrent = max(s.maxConcurrent, s.concurrent)
            return s.handler(request)
        }
        let ver = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value ?? "0"
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            s.lock.withLock { s.concurrent -= 1 }
            guard !lock.withLock({ stopped }) else { return }
            var headers = ["Content-Type": reply.contentType, "Content-Length": String(reply.body.count)]
            headers["ETag"] = reply.etag ?? "\"\(ver)\""
            let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

enum ImageFixtures {
    /// 有 JPEG 文件头的小数据（ShopCore 默认校验只看文件头）
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(7), count: 200) + [0xFF, 0xD9])
}

/// 可调的「现在」（退避用）
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ProductImageLoader.Event] = []
    func add(_ e: ProductImageLoader.Event) { lock.withLock { list.append(e) } }
    var events: [ProductImageLoader.Event] { lock.withLock { list } }
}

@Suite(.serialized) struct ProductImageTests {
    let root: URL
    let store = UUID()
    let clock = FakeClock()
    let sync = Flag(false)
    let events = EventLog()
    var base = URL(string: "http://localhost:9911")!

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)", isDirectory: true)
        ImageStubProtocol.state.reset()
    }

    func loader(enabled: Bool = true, base: URL? = nil, token: String? = "tok-1", limit: Int = ProductImageDisk.defaultLimitBytes,
                pass: Bool = false) -> ProductImageLoader {
        let c = URLSessionConfiguration.ephemeral
        if !pass { c.protocolClasses = [ImageStubProtocol.self] }
        var p = ProductImageLoader.Policy()
        p.pollInterval = .milliseconds(10)
        let b = base ?? self.base, clock = clock, sync = sync, events = events
        return ProductImageLoader(disk: ProductImageDisk(root: root, storeId: store, limitBytes: limit), enabled: enabled, policy: p,
                                  configuration: c, base: { b }, token: { token }, syncBusy: { sync.value },
                                  now: { clock.now }, onEvent: { events.add($0) })
    }

    func keys(_ n: Int, ver: Int = 1) -> [ImageKey] { (1...n).map { ImageKey(uuid($0), ver) } }

    func settle(_ l: ProductImageLoader, timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if await l.idle { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("下载器没在时限内停下（请求 \(ImageStubProtocol.requests.count) 次）", sourceLocation: sourceLocation)
    }

    // MARK: - 并发、优先级、不占同步

    @Test func atMostTwoInFlightAndAllStored() async throws {
        ImageStubProtocol.respond { _ in .init(delay: 0.15) }
        let l = loader()
        await l.prefetch(keys(10))
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 10)
        #expect(ImageStubProtocol.maxConcurrent <= 2)
        #expect(ImageStubProtocol.maxConcurrent == 2, "并发应该用满 2")
        #expect(await l.maxConcurrent <= 2)
        #expect(Set(l.disk.keys()) == Set(keys(10)))
    }

    @Test func noNewRequestsWhileSyncInFlight() async throws {
        sync.value = true
        let l = loader()
        await l.prefetch(keys(3))
        try await Task.sleep(for: .milliseconds(400))
        #expect(ImageStubProtocol.requests.isEmpty, "同步在飞时不发图片请求")
        sync.value = false
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 3)
    }

    @Test func inFlightNotCancelledBySyncStarting() async throws {
        ImageStubProtocol.respond { _ in .init(delay: 0.3) }
        let l = loader()
        await l.prefetch(keys(4))
        try await Task.sleep(for: .milliseconds(100))
        sync.value = true   // 两个在飞，后面两个等
        try await Task.sleep(for: .milliseconds(500))
        #expect(ImageStubProtocol.requests.count == 2)
        #expect(l.disk.keys().count == 2, "在飞的照常落盘")
        sync.value = false
        try await settle(l)
        #expect(l.disk.keys().count == 4)
    }

    @Test func onDemandJumpsQueue() async throws {
        ImageStubProtocol.respond { _ in .init(delay: 0.1) }
        let l = loader()
        let ks = keys(8)
        await l.prefetch(ks)
        let wanted = ImageKey(uuid(99), 3)
        await l.request(wanted)
        try await settle(l)
        let order = ImageStubProtocol.requests.map { $0.url!.path }
        let idx = order.firstIndex { $0.hasSuffix(uuid(99).uuidString.lowercased()) }
        #expect(idx != nil && idx! <= 2, "按需的插到队首（前两个在飞之后第一个）：\(order)")
    }

    @Test func prefetchRequestsAvoidLowDataModeOnDemandDoesNot() async throws {
        let l = loader()
        await l.prefetch(keys(1))
        try await settle(l)
        await l.request(ImageKey(uuid(50), 1))
        try await settle(l)
        let r = ImageStubProtocol.requests
        #expect(r[0].allowsConstrainedNetworkAccess == false)
        #expect(r[1].allowsConstrainedNetworkAccess == true)
    }

    // MARK: - 主机、地址、令牌、不跟 30x

    @Test func requestGoesToCurrentBaseWithVersionAndBearer() async throws {
        let bases = APIBaseStore(defaultBase: "https://api.yuanhuishop.cn", policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn", "47.117.184.253"]),
                                 defaults: UserDefaults(suiteName: "pi-\(UUID().uuidString)")!)!
        _ = bases.adopt("https://47.117.184.253")
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ImageStubProtocol.self]
        let l = ProductImageLoader(disk: ProductImageDisk(root: root, storeId: store), enabled: true, configuration: c,
                                   base: { bases.current }, token: { "tok-xyz" })
        let k = ImageKey(uuid(7), 4)
        await l.request(k)
        try await settle(l)
        let r = try #require(ImageStubProtocol.requests.first)
        #expect(r.url!.host == "47.117.184.253")
        #expect(r.url!.scheme == "https")
        #expect(r.url!.path == "/v1/images/\(uuid(7).uuidString.lowercased())")
        #expect(r.url!.query == "v=4")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok-xyz")
        #expect(l.disk.has(k))
    }

    @Test func redirectIsNotFollowed() async throws {
        let target = try LocalStub { _ in .init(status: 200) }
        defer { target.stop() }
        let redirector = try LocalStub { _ in .init(status: 302, headers: ["Location": "\(target.base)/v1/images/x?v=1"]) }
        defer { redirector.stop() }
        let l = loader(base: URL(string: "http://localhost:\(redirector.port)")!, pass: true)
        let k = ImageKey(uuid(1), 1)
        await l.request(k)
        try await settle(l)
        try await Task.sleep(for: .milliseconds(200))
        #expect(redirector.requests.count == 1)
        #expect(target.requests.isEmpty, "不跟 Location")
        #expect(!l.disk.has(k))
    }

    // MARK: - 状态码

    @Test func notFoundIsRememberedForThisVersion() async throws {
        ImageStubProtocol.respond { _ in .init(status: 404, contentType: "application/json", body: Data("{}".utf8)) }
        let l = loader()
        let k = ImageKey(uuid(1), 2)
        await l.request(k)
        try await settle(l)
        #expect(await l.isMissing(k))
        #expect(events.events.contains(.missing(k)))
        await l.request(k)
        await l.prefetch([k])
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 1, "404 的版本进程内不再要")
        // 新版本照常要
        ImageStubProtocol.respond { _ in .init() }
        await l.request(ImageKey(uuid(1), 3))
        try await settle(l)
        #expect(l.disk.has(ImageKey(uuid(1), 3)))
    }

    @Test func fiveConsecutive404sStopPrefetchRound() async throws {
        ImageStubProtocol.respond { _ in .init(status: 404, contentType: "application/json", body: Data("{}".utf8)) }
        let l = loader()
        await l.prefetch(keys(12))
        try await settle(l)
        let n = ImageStubProtocol.requests.count
        #expect(n >= 5 && n <= 6, "连续 5 个 404 停本轮（并发 2，最多多一个在飞）：\(n)")
    }

    @Test func forbiddenStopsForSession() async throws {
        ImageStubProtocol.respond { _ in .init(status: 403, contentType: "application/json", body: Data("{}".utf8)) }
        let l = loader()
        await l.prefetch(keys(6))
        try await settle(l)
        let n = ImageStubProtocol.requests.count
        #expect(n <= 2)
        #expect(await l.forbidden)
        await l.prefetch(keys(6, ver: 2))
        await l.request(ImageKey(uuid(40), 1))
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == n, "403 之后本会话不再请求")
    }

    @Test func unauthorizedWaitsForNextSuccessfulSync() async throws {
        ImageStubProtocol.respond { _ in .init(status: 401, contentType: "application/json", body: Data("{}".utf8)) }
        let l = loader()
        await l.prefetch(keys(4))
        try await settle(l)
        let n = ImageStubProtocol.requests.count
        #expect(await l.unauthorized)
        await l.request(ImageKey(uuid(30), 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ImageStubProtocol.requests.count == n, "401 后不再发，等同步成功")
        ImageStubProtocol.respond { _ in .init() }
        await l.prefetch(keys(4))   // 同步成功后的那一轮
        try await settle(l)
        #expect(Set(keys(4)).isSubset(of: Set(l.disk.keys())))
    }

    @Test func serverErrorsBackOffPerItemAndPauseQueue() async throws {
        ImageStubProtocol.respond { _ in .init(status: 503, contentType: "application/json", body: Data("{}".utf8)) }
        let l = loader()
        let k = ImageKey(uuid(1), 1)
        await l.request(k)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 1)
        await l.request(k)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 1, "单张退避 1 分钟内不再要")
        clock.advance(61)
        await l.request(k)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 2)
        clock.advance(61)
        await l.request(k)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 2, "第二次失败退避 5 分钟")
        clock.advance(301)
        // 第三次失败：连续 3 次 → 整队暂停 60 秒
        await l.request(k)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 3)
        ImageStubProtocol.respond { _ in .init() }
        let other = ImageKey(uuid(2), 1)
        await l.request(other)
        try await Task.sleep(for: .milliseconds(150))
        #expect(ImageStubProtocol.requests.count == 3, "整队暂停中")
        clock.advance(61)
        try await settle(l)
        #expect(l.disk.has(other))
    }

    @Test func foregroundClearsBackoff() async throws {
        ImageStubProtocol.respond { _ in .init(status: 500, contentType: "text/plain", body: Data()) }
        let l = loader()
        let k = ImageKey(uuid(1), 1)
        await l.request(k)
        try await settle(l)
        ImageStubProtocol.respond { _ in .init() }
        await l.suspend()
        await l.resume()
        await l.request(k)
        try await settle(l)
        #expect(l.disk.has(k))
    }

    @Test func transportErrorBacksOff() async throws {
        // 连不上：没有桩，直连一个没人听的端口
        let l = loader(base: URL(string: "http://127.0.0.1:9")!, pass: true)
        let k = ImageKey(uuid(1), 1)
        await l.request(k)
        try await settle(l)
        await l.request(k)
        try await settle(l)
        #expect(!l.disk.has(k))
    }

    @Test(arguments: ["type", "etag", "size", "bytes"])
    func badContentIsNotStored(kind: String) async throws {
        ImageStubProtocol.respond { _ in
            switch kind {
            case "type": return .init(contentType: "image/png")
            case "etag": return .init(etag: "\"9\"")
            case "size": return .init(body: ImageFixtures.jpeg + Data(count: 256 * 1024))
            default: return .init(body: Data("not a jpeg".utf8))
            }
        }
        let l = loader()
        let k = ImageKey(uuid(1), 1)
        await l.request(k)
        try await settle(l)
        #expect(!l.disk.has(k))
        #expect(events.events == [.missing(k)])
    }

    // MARK: - 版本、清理、开关、会话

    @Test func newVersionReplacesOldAfterLanding() async throws {
        let l = loader()
        let v1 = ImageKey(uuid(1), 1), v2 = ImageKey(uuid(1), 2)
        try l.disk.write(ImageFixtures.jpeg, for: v1)
        #expect(l.disk.best(v2)?.0 == v1, "新版还没下来：先显示旧图")
        ImageStubProtocol.respond { _ in .init(delay: 0.2) }
        await l.prefetch([v2])
        try await Task.sleep(for: .milliseconds(50))
        #expect(l.disk.has(v1), "新版落盘前旧版还在")
        try await settle(l)
        #expect(l.disk.keys() == [v2])
        #expect(ImageStubProtocol.requests.first?.url?.query == "v=2")
        #expect(events.events == [.stored(v2)])
    }

    @Test func prefetchPrunesFilesNotWanted() async throws {
        let l = loader()
        let keep = ImageKey(uuid(1), 1), gone = ImageKey(uuid(2), 1)
        try l.disk.write(ImageFixtures.jpeg, for: keep)
        try l.disk.write(ImageFixtures.jpeg, for: gone)
        await l.prefetch([keep])   // uuid(2) 归档了 / image_ver 变 0 / 不在商品表
        try await settle(l)
        #expect(l.disk.keys() == [keep])
        #expect(ImageStubProtocol.requests.isEmpty, "已有的不再下")
    }

    @Test func disableCancelsAndEmptiesDirectory() async throws {
        ImageStubProtocol.respond { _ in .init(delay: 0.5) }
        let l = loader()
        try l.disk.write(ImageFixtures.jpeg, for: ImageKey(uuid(9), 1))
        await l.prefetch(keys(4) + [ImageKey(uuid(9), 1)])
        try await Task.sleep(for: .milliseconds(100))
        await l.setEnabled(false)
        #expect(!FileManager.default.fileExists(atPath: root.path), "开关关：整个 product-images 目录删掉")
        try await Task.sleep(for: .milliseconds(700))
        #expect(!FileManager.default.fileExists(atPath: root.path), "在飞的回来也不写")
        let n = ImageStubProtocol.requests.count
        await l.prefetch(keys(4))
        await l.request(ImageKey(uuid(1), 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ImageStubProtocol.requests.count == n, "关着不请求")
        await l.setEnabled(true)
        await l.prefetch(keys(2))
        try await settle(l)
        #expect(l.disk.keys().count == 2)
    }

    @Test func lateResponseAfterSessionResetIsNotWritten() async throws {
        ImageStubProtocol.respond { _ in .init(delay: 0.4) }
        let l = loader()
        await l.prefetch(keys(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ImageStubProtocol.requests.count == 2)
        await l.reset()       // 换会话 / epoch 重建
        try await Task.sleep(for: .milliseconds(600))
        #expect(l.disk.keys().isEmpty)
        #expect(events.events.isEmpty)
    }

    @Test func startRemovesOtherStores() async throws {
        let other = ProductImageDisk(root: root, storeId: UUID())
        try other.write(ImageFixtures.jpeg, for: ImageKey(uuid(1), 1))
        let l = loader()
        try l.disk.write(ImageFixtures.jpeg, for: ImageKey(uuid(2), 1))
        await l.start()
        #expect(other.keys().isEmpty)
        #expect(l.disk.keys().count == 1)
    }

    @Test func diskEvictsOldestOverLimit() throws {
        let d = ProductImageDisk(root: root, storeId: store, limitBytes: 1000)
        let blob = ImageFixtures.jpeg + Data(count: 300)
        for i in 1...5 {
            try d.write(blob, for: ImageKey(uuid(i), 1))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))],
                                                  ofItemAtPath: d.file(ImageKey(uuid(i), 1)).path)
        }
        #expect(d.totalBytes() <= 1000)
        #expect(d.has(ImageKey(uuid(5), 1)))
        #expect(!d.has(ImageKey(uuid(1), 1)))
    }

    @Test func primeStoresWithoutRequest() async throws {
        let l = loader()
        await l.prime(ImageFixtures.jpeg, productId: uuid(3), ver: 2)
        #expect(l.disk.has(ImageKey(uuid(3), 2)))
        #expect(ImageStubProtocol.requests.isEmpty)
    }

    @Test func imageWantsSkipsZeroAndArchived() throws {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: uuid(0xD22), storeId: DemoSeed.storeId, role: .cashier, tokenRef: "t22c",
                                             storeName: "店", deviceLabel: "手机"))
        try db.applyBaseline(CatalogBaseline(products: [
            try Product(id: uuid(1), name: "有图", priceFen: Fen(100), imageVer: 3),
            try Product(id: uuid(2), name: "没图", priceFen: Fen(100)),
            try Product(id: uuid(3), name: "归档", priceFen: Fen(100), imageVer: 1, archived: true),
        ], barcodes: []))
        #expect(try db.imageWants() == [ImageKey(uuid(1), 3)])
    }

    @Test func configImagesSwitchIsOptional() throws {
        let old = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s"}"#
        #expect(try JSONDecoder().decode(RemoteConfig.self, from: Data(old.utf8)).imagesEnabled == false)
        let on = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s","product_images_enabled":true}"#
        #expect(try JSONDecoder().decode(RemoteConfig.self, from: Data(on.utf8)).imagesEnabled == true)
    }

    /// 商品图总量超过磁盘上限：被淘汰的那几张同一个进程里不再预取（老人用手机流量，不反复重下）
    @Test func evictedImagesAreNotPrefetchedAgain() async throws {
        let l = loader(limit: 500)   // 每张约 206 字节，最多留 2 张
        let want = keys(5)
        await l.prefetch(want)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 5)
        #expect(l.disk.keys().count <= 2)
        #expect(await l.evictedCount >= 3)
        await l.prefetch(want)
        try await settle(l)
        await l.prefetch(want)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 5, "淘汰掉的不再重下")
        // 屏幕上要看被淘汰的那张，仍按需下
        let gone = want.first { !l.disk.has($0) }!
        await l.request(gone)
        try await settle(l)
        #expect(ImageStubProtocol.requests.count == 6)
        #expect(l.disk.has(gone))
    }

    /// 冷启动时开关已关（或演示店）：当前店的旧缓存也整个删掉（T11）
    @Test func startWhenDisabledRemovesEverything() async throws {
        let l = loader(enabled: false)
        try l.disk.write(ImageFixtures.jpeg, for: ImageKey(uuid(2), 1))
        await l.start()
        #expect(l.disk.keys().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(ImageStubProtocol.requests.isEmpty)
    }
}
