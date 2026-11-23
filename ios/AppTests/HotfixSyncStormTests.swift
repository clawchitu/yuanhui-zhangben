import Observation
import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// 真机热修（TestFlight 0.1.0 build 11222133）：已登录的手机打开 App 后 ~150ms 一次 `/v1/sync`，停不下来。
///
/// 根因：`WindowGroup { AppRoot() }` 在 `App.body` 里，`AppRoot.init` 每次都走 `makeBoot` → `liveModel` → `attach`，
/// 建一个新的 `SyncCoordinator` 并马上同步；建的过程中读了 `sync.status`，被记成 `App.body` 的依赖 →
/// 同步改了 `status` → `App.body` 重算 → 又建一个、又同步。修法：启动时在 `App.init` 里建一次（`AppLaunch`），
/// `AppRoot.init` 只拿值。
@MainActor
final class HotfixSyncStormTests: XCTestCase {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool { lock.withLock { v } }
        func set() { lock.withLock { v = true } }
    }

    /// 假 `/v1/sync`：一律 200、空变更、没有更多
    final class SyncStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let obj: [String: Any] = [
                "results": [],
                "changes": ["products": [], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
                "cursors": ["catalog": 1, "ledger": 1], "has_more": ["catalog": false, "ledger": false],
                "total_products": 0, "server_time": iso.string(from: Date()),
                "epoch": UUID().uuidString.lowercased(), "min_build": 0,
                "device": ["role": "family", "label": "手机", "revoked": false], "store": ["name": "店"]]
            let data = try! JSONSerialization.data(withJSONObject: obj)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// 已登录的本机库 + 服务（假网络）：和真机「已有会话、重开 App」同一条启动路径（`AppRoot.liveBoot`）
    func liveLaunch() throws -> AppLaunch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try LocalDB(path: dir.appendingPathComponent(AppRoot.liveDBName).path)
        let id = UUID()
        let s = try LocalSession(deviceId: id, storeId: UUID(), role: .family, tokenRef: TokenRef.forDevice(id),
                                 storeName: "店", deviceLabel: "手机")
        try db.beginSession(s)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        try db.setMeta(.catalogDone, "1")
        let tokens = MemoryTokenStore()
        try tokens.save("t", ref: s.tokenRef)
        let defaults = UserDefaults(suiteName: "hf-\(UUID().uuidString)")!
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn",
                                               policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn"]), defaults: defaults))
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [SyncStub.self]
        let services = AppServices(api: APIClient(bases: bases, session: APIClient.makeSession(conf)), tokens: tokens,
                                   defaults: defaults, build: 1)
        let boot = try AppRoot.liveBoot(directory: dir, tokens: tokens, defaults: defaults, services: services)
        return AppLaunch(services: services, boot: boot)
    }

    func model(_ launch: AppLaunch) throws -> AppModel {
        guard case .app(let m, _) = launch.boot else { throw XCTSkip("没进已登录状态") }
        return m
    }

    /// `AppRoot.init` 被反复调用（`App.body` 重算）时不再建协调器、不再同步，也不把同步状态记成依赖
    func testAppRootInitIsCheapAndTracksNothing() async throws {
        let launch = try liveLaunch()
        let m = try model(launch)
        await m.sync!.idle()
        let created = SyncCoordinator.created, sent = SyncStats.shared.requests
        let invalidated = Flag()
        withObservationTracking {
            for _ in 0..<50 { _ = AppRoot(launch: launch) }
        } onChange: { invalidated.set() }
        m.sync!.kick()          // 同步一趟：status 会被改写
        await m.sync!.idle()
        XCTAssertEqual(SyncCoordinator.created, created, "AppRoot.init 不建同步协调器")
        XCTAssertEqual(SyncStats.shared.requests, sent + 1, "只有手动踢的那一趟")
        XCTAssertFalse(invalidated.value, "同步改了 status，也不会让 App.body 重算")
    }

    /// 反证（原来的写法）：在 body 求值里建已登录的模型，同步一改 status 就让外层失效——每次失效再建一个，就是风暴
    func testBuildingLiveModelInsideBodyWouldInvalidate() async throws {
        var launch: Result<AppLaunch, Error>?
        let invalidated = Flag()
        withObservationTracking {
            launch = Result { try liveLaunch() }
        } onChange: { invalidated.set() }
        let m = try model(try XCTUnwrap(launch).get())
        await m.sync!.idle()
        m.sync!.kick()
        await m.sync!.idle()
        XCTAssertTrue(invalidated.value, "建模型时读了 sync.status，被记成依赖（所以不许在 AppRoot.init 里建）")
    }

    /// 空闲时的节奏：只有定时器在踢。间隔按 15 秒 → 0.25 秒等比缩小，「空闲 60 秒」≈ 0.95 秒，请求 ≤ 5 次
    func testIdleRequestsStayAtTimerPace() async throws {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: UUID(), role: .family, tokenRef: "t",
                                             storeName: "店", deviceLabel: "手机"))
        try db.setMeta(.serverEpoch, UUID().uuidString)
        let server = S22aTests.FakeServer()
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(),
                         defaults: UserDefaults(suiteName: "hf-idle")!)
        let sync = SyncCoordinator(db: db, build: 1, interval: .milliseconds(250)) { try server.handle($0) }
        m.attach(sync)            // 和正常启动一样：接上就开定时器、先同步一趟；每趟跑完刷新首页的数
        m.refreshRecent()         // 首页 onAppear
        try await Task.sleep(for: .milliseconds(950))
        sync.stop()
        await sync.idle()
        XCTAssertGreaterThanOrEqual(server.requests, 2)
        XCTAssertLessThanOrEqual(server.requests, 5, "空闲「60 秒」内同步请求 ≤ 5（实际 \(server.requests)）")
    }
}

/// 真机热修：扫到未知码 → 问服务器查码 → 查到预填名称 / 规格；失败、超时让人手填；同一码不重复查
@MainActor
final class HotfixLookupTests: XCTestCase {
    /// 假服务器：按条码回不同的结果，记下收到的请求
    final class LookupStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var paths: [String] = []
        nonisolated(unsafe) static var auth: [String?] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path
            Self.paths.append(path)
            Self.auth.append(request.value(forHTTPHeaderField: "Authorization"))
            if path.hasSuffix("/6900000000000") {   // 连不上
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            let (status, obj): (Int, [String: Any]) = switch path {
            case "/v1/barcode-lookup/6921168509256": (200, ["found": true, "name": "农夫山泉 饮用天然水550ml", "spec": "550ml", "has_image": false])
            case "/v1/barcode-lookup/6920152400777": (200, ["found": true, "name": "康师傅红烧牛肉面碗装", "spec": "面饼+配料106克", "has_image": false])
            case "/v1/barcode-lookup/6911111111111": (429, ["code": "lookup_quota_exceeded", "retry_after_s": 60])
            default: (200, ["found": false])
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: obj))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func lookup() throws -> ServerNameLookup {
        LookupStub.paths = []; LookupStub.auth = []
        let defaults = UserDefaults(suiteName: "hf-lookup-\(UUID().uuidString)")!
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn",
                                               policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn"]), defaults: defaults))
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [LookupStub.self]
        let tokens = MemoryTokenStore()
        try tokens.save("tok", ref: "ref")
        return ServerNameLookup(api: APIClient(bases: bases, session: APIClient.makeSession(conf)), tokens: tokens, tokenRef: "ref",
                                memo: NameLookupMemo())
    }

    func testFoundPrefillsNameWithSpecAndAsksOnce() async throws {
        let l = try lookup()
        let r1 = await l.lookup("6921168509256")
        XCTAssertEqual(r1, .found(name: "农夫山泉 饮用天然水550ml", unit: nil), "名称里已经有规格就不重复拼")
        XCTAssertEqual(LookupStub.paths, ["/v1/barcode-lookup/6921168509256"], "确实问了服务器")
        XCTAssertEqual(LookupStub.auth, ["Bearer tok"])
        let r2 = await l.lookup("6920152400777")
        XCTAssertEqual(r2, .found(name: "康师傅红烧牛肉面碗装 面饼+配料106克", unit: nil), "规格拼在名称后面")
        _ = await l.lookup("6921168509256")
        _ = await l.lookup("6999999999999")
        _ = await l.lookup("6999999999999")
        XCTAssertEqual(LookupStub.paths.count, 3, "同一码（查到或明确没查到）不再发请求")
    }

    func testFailuresFallBackToManualAndAreNotMemoized() async throws {
        let l = try lookup()
        let notFound = await l.lookup("6999999999999")
        XCTAssertEqual(notFound, .notFound)
        let offline = await l.lookup("6900000000000")
        XCTAssertEqual(offline, .offline, "连不上 → 25e，照样能手填登记")
        let quota = await l.lookup("6911111111111")
        XCTAssertEqual(quota, .notFound, "额度用完 / 限速 → 当没查到，手填")
        _ = await l.lookup("6900000000000")
        _ = await l.lookup("6911111111111")
        XCTAssertEqual(LookupStub.paths.count, 5, "没网、出错不记，下次进来再查")
        let bad = await l.lookup("69 01/..")
        XCTAssertEqual(bad, .notFound)
        XCTAssertEqual(LookupStub.paths.count, 5, "不合法的码不发请求")
    }

    /// 正常启动（有网络服务）用真实查码；夹具和 -uiOffline 用桩
    func testLiveModelUsesServerLookup() throws {
        let db = try LocalDB.inMemory()
        let s = try LocalSession(deviceId: UUID(), storeId: UUID(), role: .family, tokenRef: "ref", storeName: "店", deviceLabel: "手机")
        try db.beginSession(s)
        let m = AppModel(db: db, session: s, figures: HomeFigures())
        XCTAssertTrue(m.nameLookup(offline: false) is StubNameLookup, "夹具没有网络服务")
        let defaults = UserDefaults(suiteName: "hf-lookup-m")!
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn",
                                               policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn"]), defaults: defaults))
        m.services = AppServices(api: APIClient(bases: bases), tokens: MemoryTokenStore(), defaults: defaults, build: 1)
        XCTAssertTrue(m.nameLookup(offline: false) is ServerNameLookup, "正常启动问服务器")
        XCTAssertTrue(m.nameLookup(offline: true) is StubNameLookup)
    }
}
