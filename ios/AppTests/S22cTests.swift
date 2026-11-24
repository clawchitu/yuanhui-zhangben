import ShopCore
import UIKit
import XCTest
@testable import YuanhuiZhangben

/// URLProtocol 桩：`/v1/config` 回 `config`，`/v1/images/…` 回一张真 JPEG（ETag = 请求的 v）。记下请求、最大并发
final class S22cStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var config: String? = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s"}"#
    nonisolated(unsafe) static var imageDelay: TimeInterval = 0
    nonisolated(unsafe) static var imageStatus = 200
    static let lock = NSLock()
    nonisolated(unsafe) static var log: [URLRequest] = []
    nonisolated(unsafe) static var concurrent = 0
    nonisolated(unsafe) static var maxConcurrent = 0
    static var imageRequests: [URLRequest] { lock.withLock { log.filter { $0.url!.path.hasPrefix("/v1/images/") } } }
    static func reset() {
        lock.withLock { log = []; concurrent = 0; maxConcurrent = 0 }
        config = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s"}"#
        imageDelay = 0; imageStatus = 200
    }
    static let jpeg: Data = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { c in
        UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }.jpegData(compressionQuality: 0.8)!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.log.append(request); Self.concurrent += 1; Self.maxConcurrent = max(Self.maxConcurrent, Self.concurrent) }
        let finish: @Sendable (Int, [String: String], Data) -> Void = { [self] status, headers, body in
            Self.lock.withLock { Self.concurrent -= 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.path == "/v1/config" {
            guard let c = Self.config else {
                Self.lock.withLock { Self.concurrent -= 1 }
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            finish(200, ["Content-Type": "application/json"], Data(c.utf8)); return
        }
        let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value ?? "0"
        let status = Self.imageStatus
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.imageDelay) {
            if status == 200 { finish(200, ["Content-Type": "image/jpeg", "ETag": "\"\(v)\""], Self.jpeg) }
            else { finish(status, ["Content-Type": "application/json"], Data("{}".utf8)) }
        }
    }
}

/// S22c 商品图的 App 侧（plan-v2 §8 S22c、§14 T11；Fable 裁定 1–10）
@MainActor
final class S22cTests: XCTestCase {
    let suite = "S22cTests"
    var defaults: UserDefaults!
    var root: URL!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s22c-\(UUID().uuidString)", isDirectory: true)
        S22cStub.reset()
    }

    var stubConfig: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [S22cStub.self]
        return c
    }

    func db(_ role: Role) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                             tokenRef: "t", storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        try db.writer.write { try $0.execute(sql: "UPDATE product SET image_ver = 1") }
        return db
    }

    func images(_ db: LocalDB?, enabled: Bool = true, blocked: Bool = false, syncBusy: @escaping @Sendable () -> Bool = { false }) -> ProductImages {
        ProductImages(db: db, disk: ProductImageDisk(root: root, storeId: DemoSeed.storeId), enabled: enabled, blocked: blocked,
                      configuration: stubConfig, base: { URL(string: "https://api.yuanhuishop.cn")! }, token: { "tok" }, syncBusy: syncBusy)
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ ok: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await ok() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等不到：\(what)")
    }

    func services() -> AppServices {
        let bases = APIBaseStore(defaultBase: "http://localhost:1", policy: APIEnvironment.policy, defaults: defaults)!
        return AppServices(api: APIClient(bases: bases, session: APIClient.makeSession(stubConfig)), tokens: MemoryTokenStore(), defaults: defaults)
    }

    // MARK: - 后台低优先级，不占同步

    /// 同步在飞时一个图片请求都不发；同步成功后（商品流已拉完）预取，并发不超过 2，主机是自家服务器
    func testPrefetchWaitsForSyncAndRunsAfterSuccess() async throws {
        let db = try db(.family), server = S22aTests.FakeServer()
        server.delay = 0.6
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        let sync = SyncCoordinator(db: db, build: 1) { try server.handle($0) }
        m.sync = sync
        let busy = sync.busy
        S22cStub.imageDelay = 0.05
        let imgs = images(db, syncBusy: { busy.value })
        m.attachImages(imgs)
        // 同步开跑后立刻要一张图（屏幕上的 Thumb）
        sync.kick()
        XCTAssertTrue(busy.value)
        let water = ImageKey(UIFixture.DemoSeedIds.water, 1)
        _ = await imgs.load(water)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(sync.running)
        XCTAssertEqual(S22cStub.imageRequests.count, 0, "同步在飞时不发图片请求")
        await sync.idle()
        XCTAssertFalse(busy.value)
        let wants = try db.imageWants().count
        await waitUntil("全部预取下来") { imgs.loader.disk.keys().count == wants }
        XCTAssertLessThanOrEqual(S22cStub.maxConcurrent, 2)
        XCTAssertEqual(Set(S22cStub.imageRequests.map { $0.url!.host! }), ["api.yuanhuishop.cn"])
        XCTAssertEqual(server.requests, 1, "图片不走同步请求")
    }

    // MARK: - 版本刷新、旧图先顶着

    func testImageVersionChangeRefreshes() async throws {
        let db = try db(.family)
        let imgs = images(db)
        let id = UIFixture.DemoSeedIds.cola
        let v1 = ImageKey(id, 1), v2 = ImageKey(id, 2)
        try imgs.loader.disk.write(S22cStub.jpeg, for: v1)
        let first = await imgs.load(v2)
        XCTAssertNotNil(first, "新版还没下来：先显示旧图")
        await waitUntil("新版到了") { imgs.arrivals[v2] == 1 }
        XCTAssertEqual(S22cStub.imageRequests.last?.url?.query, "v=2")
        do { let v = await imgs.load(v2); XCTAssertNotNil(v) }
        XCTAssertNotNil(imgs.cached(v2))
        XCTAssertEqual(imgs.loader.disk.keys(), [v2], "新版落盘后旧版删掉")
    }

    /// 没图（404）：显示首字（load 给 nil），这一版不再请求
    func testMissingImageShowsInitial() async throws {
        S22cStub.imageStatus = 404
        let imgs = images(try db(.family))
        let k = ImageKey(UIFixture.DemoSeedIds.water, 1)
        let r = await imgs.load(k)
        XCTAssertNil(r)
        await waitUntil("404 回来") { imgs.arrivals[k] == 1 }
        do { let v = await imgs.load(k); XCTAssertNil(v) }
        XCTAssertEqual(S22cStub.imageRequests.count, 1)
    }

    // MARK: - T11 开关

    /// 从没取到过配置按关；缺字段当关；取到 true 打开；见 false 当场清内存（Thumb 回首字）、删整个目录、不再请求；离线沿用上次值
    func testSwitchFollowsConfigAndOffClearsCache() async throws {
        let s = services()
        XCTAssertFalse(s.imagesEnabled, "从没取到过：按关")
        await s.refreshConfig()
        XCTAssertFalse(s.imagesEnabled, "缺字段当 false")
        let db = try db(.family)
        let imgs = images(db, enabled: s.imagesEnabled)
        s.onImagesSwitch = { [weak imgs] in imgs?.setEnabled($0) }
        XCTAssertFalse(imgs.enabled)

        S22cStub.config = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s","product_images_enabled":true}"#
        await s.refreshConfig()
        XCTAssertTrue(s.imagesEnabled)
        XCTAssertTrue(imgs.enabled)
        let wants = try db.imageWants().count
        await waitUntil("开关 false→true 触发一轮预取") { imgs.loader.disk.keys().count == wants }
        let k = ImageKey(UIFixture.DemoSeedIds.water, 1)
        do { let v = await imgs.load(k); XCTAssertNotNil(v) }
        XCTAssertNotNil(imgs.cached(k))
        let gen = imgs.generation

        S22cStub.config = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s","product_images_enabled":false}"#
        await s.refreshConfig()
        XCTAssertFalse(imgs.enabled)
        XCTAssertNil(imgs.cached(k), "当场清内存")
        XCTAssertGreaterThan(imgs.generation, gen, "Thumb 手上的图作废，立即回首字")
        await waitUntil("整个 product-images 目录删掉") { !FileManager.default.fileExists(atPath: self.root.path) }
        let n = S22cStub.imageRequests.count
        imgs.prefetch()
        do { let v = await imgs.load(k); XCTAssertNil(v) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(S22cStub.imageRequests.count, n, "关着不请求")

        // 离线：沿用上次值（关）；重开 App 也是
        S22cStub.config = nil
        await s.refreshConfig()
        XCTAssertFalse(s.imagesEnabled)
        XCTAssertFalse(services().imagesEnabled)
        S22cStub.config = #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s","product_images_enabled":true}"#
        await s.refreshConfig()
        S22cStub.config = nil
        XCTAssertTrue(services().imagesEnabled, "离线启动沿用上次的开")
    }

    // MARK: - 身份

    func testCashierSeesImages() async throws {
        let imgs = images(try db(.cashier))
        let k = ImageKey(UIFixture.DemoSeedIds.water, 1)
        _ = await imgs.load(k)
        await waitUntil("收银员手机下到图") { imgs.arrivals[k] == 1 }
        do { let v = await imgs.load(k); XCTAssertNotNil(v) }
    }

    func testDemoStoreNeverRequests() async throws {
        let s = services()
        let deviceId = UUID()
        s.defaults.set(deviceId.uuidString, forKey: AuthDefaults.demoDeviceId)
        XCTAssertTrue(s.isDemoSession(deviceId))
        let imgs = images(try db(.family), enabled: true, blocked: s.isDemoSession(deviceId))
        XCTAssertFalse(imgs.enabled)
        imgs.prefetch()
        do { let v = await imgs.load(ImageKey(UIFixture.DemoSeedIds.water, 1)); XCTAssertNil(v) }
        imgs.setEnabled(true)
        XCTAssertFalse(imgs.enabled)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(S22cStub.imageRequests.isEmpty)
    }

    /// 会话结束（退出、被踢、换身份）、epoch 重建：清内存、删整目录
    func testShutdownAndResetEmptyCache() async throws {
        let imgs = images(try db(.family))
        let k = ImageKey(UIFixture.DemoSeedIds.water, 1)
        try imgs.loader.disk.write(S22cStub.jpeg, for: k)
        do { let v = await imgs.load(k); XCTAssertNotNil(v) }
        imgs.reset()
        XCTAssertNil(imgs.cached(k))
        await waitUntil("epoch 重建：目录删掉") { !FileManager.default.fileExists(atPath: self.root.path) }
        try imgs.loader.disk.write(S22cStub.jpeg, for: k)
        imgs.shutdown()
        await waitUntil("会话结束：目录删掉") { !FileManager.default.fileExists(atPath: self.root.path) }
        do { let v = await imgs.load(k); XCTAssertNil(v) }
    }

    /// 登录时记下是不是演示店
    func testEstablishRecordsDemoStore() async throws {
        let s = services()
        let db = try LocalDB.inMemory()
        let json = #"{"token":"t1","epoch":"e","role":"family","store":{"name":"演示小店","is_demo":true},"label":"l"}"#
        let grant = try JSONDecoder().decode(SessionGrant.self, from: Data(json.utf8))
        let id = UUID()
        _ = try await s.establish(grant, deviceId: id, db: db)
        XCTAssertTrue(s.isDemoSession(id))
        let json2 = #"{"token":"t2","epoch":"e","role":"family","store":{"name":"店"},"label":"l"}"#
        let id2 = UUID()
        _ = try await s.establish(try JSONDecoder().decode(SessionGrant.self, from: Data(json2.utf8)), deviceId: id2, db: db)
        XCTAssertFalse(s.isDemoSession(id2))
    }
}
