import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// §14 S15-4（S21 改）：没有会话、会话的令牌不在钥匙串里、`demo-local` 遗留会话，都进登录页；
/// 不建会话、不写演示数据。Beta / Release 的实际表现由 `scripts/release-check.sh` 验证。
@MainActor
final class LaunchPolicyTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "launch-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var liveDB: URL { dir.appendingPathComponent(AppRoot.liveDBName) }

    private func boot(_ tokens: TokenStore) throws -> AppRoot.Boot {
        try AppRoot.liveBoot(directory: dir, tokens: tokens, defaults: defaults)
    }

    func testNoSessionShowsLoginAndCreatesNothing() throws {
        guard case .signedOut = try boot(MemoryTokenStore()) else { return XCTFail("没有会话应出登录页") }
        XCTAssertNil(try LocalDB(path: liveDB.path).currentSession())
        guard case .signedOut = try boot(MemoryTokenStore()) else { return XCTFail("第二次启动也是登录页") }
    }

    /// 验收（S15-4）：库里预置一条 demo-local 会话，启动后进登录页、会话已删；改过的手机名留着第一次登录时报
    func testLegacyDemoLocalSessionIsCleared() throws {
        let db = try LocalDB(path: liveDB.path)
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: UUID(), role: .family, tokenRef: "demo-local",
                                             storeName: "元辉烟酒店", deviceLabel: "爸爸的手机"))
        let tokens = MemoryTokenStore()
        try tokens.save("x", ref: "demo-local")  // 就算钥匙串里有同名条目也不算登录
        guard case .signedOut = try boot(tokens) else { return XCTFail("demo-local 会话不当作已登录") }
        XCTAssertNil(try LocalDB(path: liveDB.path).currentSession(), "会话已删")
        XCTAssertEqual(defaults.string(forKey: AuthDefaults.pendingDeviceLabel), "爸爸的手机")
    }

    func testSessionWithoutKeychainTokenIsNotSignedIn() throws {
        let db = try LocalDB(path: liveDB.path)
        let id = UUID()
        try db.beginSession(try LocalSession(deviceId: id, storeId: UUID(), role: .family, tokenRef: TokenRef.forDevice(id),
                                             storeName: "店", deviceLabel: "手机"))
        guard case .signedOut = try boot(MemoryTokenStore()) else { return XCTFail() }
        XCTAssertNil(defaults.string(forKey: AuthDefaults.pendingDeviceLabel))
    }

    /// 杀掉重开仍是登录状态：库里有会话、钥匙串里有令牌
    func testExistingSessionWithTokenIsUsed() throws {
        let db = try LocalDB(path: liveDB.path)
        let id = UUID()
        let s = try LocalSession(deviceId: id, storeId: UUID(), role: .cashier, tokenRef: TokenRef.forDevice(id),
                                 storeName: "店", deviceLabel: "手机")
        try db.beginSession(s)
        let tokens = MemoryTokenStore()
        try tokens.save("t", ref: s.tokenRef)
        guard case .app(let model, _) = try boot(tokens) else { return XCTFail() }
        XCTAssertEqual(model.session.deviceId, id)
        XCTAssertEqual(model.role, .cashier)
    }

    func testFixtureArgumentsInDebug() {
        XCTAssertEqual(UIFixture.injectedRoutes(from: ["-uiRoute", "settings,stockIn,nope"]), [.settings, .stockIn])
        guard case .app(let model, let path) = AppRoot.makeBoot(["-uiFixture", "home", "-uiRole", "cashier",
                                                                  "-uiRoute", "stockIn"]) else { return XCTFail() }
        XCTAssertEqual(model.role, .cashier)
        XCTAssertEqual(path, [.stockIn])
        XCTAssertFalse(AppRoot.needsServices(["-uiFixture", "home"]))
        XCTAssertTrue(AppRoot.needsServices([]))
    }
}
