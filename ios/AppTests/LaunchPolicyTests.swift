import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// §14 S15-4：没有会话时怎么办。Beta / Release 只有 `.signedOut`（`NoSessionPolicy` 在非 Debug 构建里没有
/// `demoSession` 分支）；这里在 Debug 下把两种策略都注入测一遍，非 Debug 构建的实际表现由
/// `scripts/release-check.sh`（Release 构建 + `ReleaseBuildUITests` + 查二进制里没有夹具参数）验证。
@MainActor
final class LaunchPolicyTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 演示数据里的一样商品（青岛啤酒）
    private func demoProductId() throws -> UUID {
        try XCTUnwrap(DemoSeed.baseline(includePrivate: false).products.first { $0.name.hasPrefix("青岛啤酒") }?.id)
    }

    private var liveDB: URL { dir.appendingPathComponent(AppRoot.liveDBName) }
    private var demoDB: URL { dir.appendingPathComponent(AppRoot.demoDBName) }

    /// 非 Debug 的路径：不建会话、不写演示数据，出「还没登录」
    func testSignedOutPolicyCreatesNoSessionAndNoDemoData() throws {
        guard case .signedOut = try AppRoot.liveBoot(directory: dir, policy: .signedOut) else {
            return XCTFail("没有会话时应出「还没登录」页")
        }
        let db = try LocalDB(path: liveDB.path)
        XCTAssertNil(try db.currentSession(), "不建会话")
        XCTAssertNil(try db.product(try demoProductId()), "不写演示数据")
        XCTAssertFalse(FileManager.default.fileExists(atPath: demoDB.path), "不开演示库")
        // 再启动一次还是没登录（第一次什么也没留下）
        guard case .signedOut = try AppRoot.liveBoot(directory: dir, policy: .signedOut) else {
            return XCTFail("第二次启动也应是「还没登录」")
        }
    }

    /// Debug 的演示会话只写演示库，正式库不动
    func testDebugDemoSessionIsIsolatedFromLiveDB() throws {
        guard case .app(let model, let path) = try AppRoot.liveBoot(directory: dir, policy: .demoSession) else {
            return XCTFail("Debug 应开演示会话")
        }
        XCTAssertEqual(path, [])
        XCTAssertEqual(model.role, .family)
        XCTAssertEqual(model.session.tokenRef, "demo-local")
        XCTAssertNotNil(try model.db.product(try demoProductId()), "演示库里有演示数据")
        let live = try LocalDB(path: liveDB.path)
        XCTAssertNil(try live.currentSession(), "正式库里没有演示会话")
        XCTAssertNil(try live.product(try demoProductId()), "正式库里没有演示数据")
        XCTAssertTrue(FileManager.default.fileExists(atPath: demoDB.path))
        // 再开一次用的是同一个演示会话，不会重复装
        guard case .app(let again, _) = try AppRoot.liveBoot(directory: dir, policy: .demoSession) else { return XCTFail() }
        XCTAssertEqual(again.session.deviceId, model.session.deviceId)
    }

    /// 正式库里已经有会话时两种策略都直接用它
    func testExistingLiveSessionIsUsedUnderEitherPolicy() throws {
        let db = try LocalDB(path: liveDB.path)
        let s = try LocalSession(deviceId: UUID(), storeId: UUID(), role: .cashier, tokenRef: "real",
                                 storeName: "店", deviceLabel: "手机")
        try db.beginSession(s)
        for policy in [NoSessionPolicy.signedOut, .demoSession] {
            guard case .app(let model, _) = try AppRoot.liveBoot(directory: dir, policy: policy) else {
                return XCTFail("\(policy)")
            }
            XCTAssertEqual(model.session.deviceId, s.deviceId)
            XCTAssertEqual(model.role, .cashier)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: demoDB.path), "有会话就不碰演示库")
    }

    func testDebugBuildUsesDemoSession() {
        XCTAssertEqual(NoSessionPolicy.current, .demoSession)
    }

    /// 夹具参数：Debug 下照常认；`-uiRoute` 塞进导航栈的路由按顺序解析
    func testFixtureArgumentsInDebug() {
        XCTAssertEqual(UIFixture.injectedRoutes(from: ["-uiRoute", "settings,stockIn,nope"]), [.settings, .stockIn])
        XCTAssertEqual(UIFixture.injectedRoutes(from: []), [])
        guard case .app(let model, let path) = AppRoot.makeBoot(["-uiFixture", "home", "-uiRole", "cashier",
                                                                  "-uiRoute", "stockIn"]) else { return XCTFail() }
        XCTAssertEqual(model.role, .cashier)
        XCTAssertEqual(path, [.stockIn])
        guard case .app(_, let path2) = AppRoot.makeBoot(["-uiFixture", "settings", "-uiRole", "cashier",
                                                          "-uiRoute", "devices"]) else { return XCTFail() }
        XCTAssertEqual(path2, [.settings, .devices])
    }
}
