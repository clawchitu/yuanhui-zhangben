import ShopCore
import XCTest
@testable import YuanhuiZhangben

@MainActor
final class NavigationTests: XCTestCase {
    /// 收银员到不了的页（S15 验收）+ 账号、设备管理、改名（§6.2）
    static let cashierForbidden: Set<Route> = [.stockIn, .reports, .products, .count, .expiry, .pairing,
                                               .devices, .account, .deviceName]

    func testRouteGateFollowsCapabilities() {
        let cashier = Capabilities(role: .cashier)
        for r in Route.allCases {
            XCTAssertEqual(r.isAllowed(cashier), !Self.cashierForbidden.contains(r), "收银员 \(r)")
        }
        for role in [Role.family, .review] {
            let caps = Capabilities(role: role)
            for r in Route.allCases { XCTAssertTrue(r.isAllowed(caps), "\(role) \(r)") }
        }
        let revoked = Capabilities(role: .revoked)
        XCTAssertFalse(Route.stockIn.isAllowed(revoked))
    }

    /// RouteView 兜底：每个路由 × 每种身份，没能力的一律出「用不了」页，有能力的出真页面或占位页
    func testRouteViewRendersDeniedForEveryForbiddenRoute() {
        for role in Role.allCases {
            let caps = Capabilities(role: role)
            for r in Route.allCases {
                let content = RouteView.content(for: r, capabilities: caps)
                if !r.isAllowed(caps) {
                    XCTAssertEqual(content, .denied, "\(role) \(r)")
                } else {
                    XCTAssertNotEqual(content, .denied, "\(role) \(r)")
                }
            }
        }
        let cashier = Capabilities(role: .cashier)
        for r in Self.cashierForbidden { XCTAssertEqual(RouteView.content(for: r, capabilities: cashier), .denied, "\(r)") }
        XCTAssertEqual(RouteView.content(for: .settings, capabilities: cashier), .settings)
        XCTAssertEqual(RouteView.content(for: .deviceName, capabilities: Capabilities(role: .family)), .deviceName)
    }

    /// 首页和设置页的版式只有一个来源：有进货能力 = 家用版式；收银员和被踢设备都是收银员版式
    func testShellLayoutHasSingleSource() throws {
        let expected: [Role: ShellLayout] = [.family: .family, .review: .family, .cashier: .cashier, .revoked: .cashier]
        for role in Role.allCases {
            XCTAssertEqual(ShellLayout(Capabilities(role: role)), expected[role], "\(role)")
        }
        let suite = "s15-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for role in [Role.family, .cashier, .review] {
            let m = try model(role, defaults: defaults)
            XCTAssertEqual(m.layout, expected[role])
            XCTAssertEqual(Route.settings.title(m.layout), role == .cashier ? "设置" : "更多")
        }
    }

    /// 25a：「没同步」和「快过期」同时出现时没同步的在上；收银员没有快过期黄条
    func testRemindersUnsyncedFirst() {
        var f = HomeFigures.design
        f.staleUnsyncedCount = 5
        f.expiringCount = 3
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)), [.unsynced(total: 5, overdue: 5), .expiring(3)])
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .cashier)), [.unsynced(total: 5, overdue: 5)])
        f.staleUnsyncedCount = 0
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)), [.expiring(3)])
        f.expiringCount = 0
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)), [])
    }

    private func model(_ role: Role, defaults: UserDefaults) throws -> AppModel {
        let db = try LocalDB.inMemory()
        let s = try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                 tokenRef: "t", storeName: "元辉烟酒店", deviceLabel: role == .cashier ? "小王的手机" : "新手机")
        try db.beginSession(s)
        return AppModel(db: db, session: s, figures: .design, defaults: defaults)
    }

    /// §14 S15-1（S16 接）：设置页「扫码枪」的字来自真实连接状态；只有夹具用稿子上的值
    func testScannerConnectedComesFromTheGunMonitor() throws {
        let db = try LocalDB.inMemory()
        let s = try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family,
                                 tokenRef: "t", storeName: "元辉烟酒店", deviceLabel: "新手机")
        try db.beginSession(s)
        var live = HomeFigures()
        XCTAssertNil(live.scannerConnected, "正常启动不带假数")
        XCTAssertTrue(AppModel(db: db, session: s, figures: live, gun: ScannerGunMonitor(probe: { true })).scannerConnected)
        XCTAssertFalse(AppModel(db: db, session: s, figures: live, gun: ScannerGunMonitor(probe: { false })).scannerConnected)
        live.scannerConnected = false
        XCTAssertFalse(AppModel(db: db, session: s, figures: live, gun: ScannerGunMonitor(probe: { true })).scannerConnected,
                       "夹具给了稿子上的值就用它")
    }

    func testScannerRouteIsARealPage() {
        XCTAssertNil(Route.scanner.plannedIn)
        for role in [Role.family, .cashier, .review] {
            XCTAssertEqual(RouteView.content(for: .scanner, capabilities: Capabilities(role: role)), .scanner)
        }
    }

    /// 16：选择存在本机，同一台手机（同一个设备 id）重开后认得做过了；家用顺带改名，收银员不改名
    func testFinishOnboardingPersists() throws {
        let suite = "s15-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fam = try model(.family, defaults: defaults)
        XCTAssertFalse(fam.onboarded)
        try fam.finishOnboarding(largeText: false, deviceName: "爸爸的手机")
        XCTAssertTrue(fam.onboarded)
        XCTAssertEqual(defaults.object(forKey: AppSettings.largeTextModeKey) as? Bool, false)
        XCTAssertEqual(fam.session.deviceLabel, "爸爸的手机")
        XCTAssertEqual(try fam.db.currentSession()?.deviceLabel, "爸爸的手机")
        XCTAssertTrue(try model(.family, defaults: defaults).onboarded, "同一台手机重开：不再出 16")
        XCTAssertFalse(try model(.cashier, defaults: defaults).onboarded, "换了会话（新设备 id）：再选一次")

        let cashier = try model(.cashier, defaults: defaults)
        try cashier.finishOnboarding(largeText: true, deviceName: "别的名字")
        XCTAssertEqual(cashier.session.deviceLabel, "小王的手机", "16b 不起名")
        XCTAssertEqual(defaults.object(forKey: AppSettings.largeTextModeKey) as? Bool, true)
    }

    func testDeviceNameInitialSelection() {
        XCTAssertEqual(DeviceNamePicker.initialSelection(current: "新手机"), "柜台手机")
        XCTAssertEqual(DeviceNamePicker.initialSelection(current: "妈妈的手机"), "妈妈的手机")
    }

    func testDesignNowIsThursdayNov19() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: UIFixture.designNow)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.weekday], [2026, 11, 19, 19, 48, 5])
    }
}
