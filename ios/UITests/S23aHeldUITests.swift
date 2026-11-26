import XCTest

/// S23a 待确认的账、退出登录的确认面板（plan-v2 §8 S23a 验收，夹具 + 本机桩）。桩是 `S23aUITests.swift` 里的 `DeviceStub`。
/// 「记上后出现在记的账里」要真服务器下发流水，在 `S23aLiveUITests`。
@MainActor
final class S23aHeldUITests: XCTestCase {
    private var stub: DeviceStub!
    static let a = "aaaaaaaa-1111-4222-8333-444444444444"
    static let b = "bbbbbbbb-1111-4222-8333-444444444444"

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try DeviceStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func launch(route: String, api: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", "family", "-uiLargeText", "on", "-uiRoute", route]
            + (api ? ["-uiAPI", "http://localhost:\(stub.port)"] : []) + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 已登录的手机里，退出了还有账的手机一行「去看看」→ 待确认的账：逐笔「记上 / 不要」。
    /// 记上直接发；「不要」先弹确认，「再想想」什么都不发；两笔都处理完显示「没有要确认的账了」
    func testAcceptAndDiscardOneByOne() {
        stub.held = [DeviceStub.heldStockIn(id: Self.a), DeviceStub.heldStockIn(id: Self.b)]
        let app = launch(route: "devices")
        let go = el(app, "devices.held.旧手机")
        XCTAssertTrue(go.waitForExistence(timeout: 15))
        XCTAssertTrue(el(app, "devices.heldRow.旧手机").label.contains("退出前还有 2 笔账等你确认"))
        go.tap()
        XCTAssertTrue(el(app, "page.held").waitForExistence(timeout: 10))
        let accept = app.buttons.matching(identifier: "held.accept")
        wait("两笔") { accept.count == 2 }
        let text = el(app, "held.text").label
        XCTAssertTrue(text.contains("进货") && text.contains("青岛啤酒 500ml") && text.contains("3 罐") && text.contains("¥36.00"), text)
        XCTAssertTrue(app.staticTexts["旧手机记的"].exists)
        shot(app, "held")
        accept.element(boundBy: 0).tap()
        wait("记上了一笔") { accept.count == 1 }
        XCTAssertEqual(stub.resolves.map(\.1), ["accept"])
        XCTAssertEqual(el(app, "held.flash").label, "记上了，记的账里能看到")
        app.buttons["held.discard"].firstMatch.tap()
        XCTAssertEqual(el(app, "confirm.title").label, "这笔不要了？")
        el(app, "held.discard.cancel").tap()
        wait("面板关上") { !self.el(app, "confirm.title").exists }
        XCTAssertEqual(stub.resolves.count, 1, "「再想想」不发")
        app.buttons["held.discard"].firstMatch.tap()
        el(app, "held.discard.confirm").tap()
        XCTAssertTrue(el(app, "held.empty").waitForExistence(timeout: 10))
        XCTAssertEqual(stub.resolves.map(\.0), [Self.a, Self.b])
        XCTAssertEqual(stub.resolves.map(\.1), ["accept", "discard"])
    }

    /// 账面变了（服务器说只能不要）：列表里一开始就没有「记上」并说明原因；记上时才发现 409 的，按钮也收起来
    func testOnlyDiscardWhenStale() {
        stub.held = [DeviceStub.heldStockIn(id: Self.a, canAccept: false, type: "count"), DeviceStub.heldStockIn(id: Self.b)]
        stub.staleIds = [Self.b]
        let app = launch(route: "held")
        let reasons = app.staticTexts.matching(identifier: "held.onlyDiscard")
        wait("第一笔只能不要") { reasons.count == 1 }
        XCTAssertEqual(reasons.firstMatch.label, "账面已经变了，这笔只能不要（要的话重新盘一次）")
        XCTAssertEqual(app.buttons.matching(identifier: "held.accept").count, 1)
        app.buttons["held.accept"].tap()
        wait("409 后也只能不要") { reasons.count == 2 && app.buttons.matching(identifier: "held.accept").count == 0 }
    }

    /// 原来是收银员的手机补传的进货（T37 的老数据）：说明是收银员不能做的
    func testCashierHeldOnlyDiscard() {
        stub.held = [DeviceStub.heldStockIn(id: Self.a, label: "小李", role: "cashier", canAccept: false)]
        let app = launch(route: "held")
        XCTAssertTrue(el(app, "held.onlyDiscard").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "held.onlyDiscard").label, "原来是收银员的手机，收银员不能做这个，只能不要")
        XCTAssertTrue(app.staticTexts["小李（收银员）记的"].exists)
        XCTAssertFalse(app.buttons["held.accept"].exists)
    }

    /// 设置页：有待确认的账才出「待确认的账 N 笔」（N 来自服务器的手机列表）
    func testSettingsShowsHeldCount() {
        let app = launch(route: "settings")
        let item = el(app, "settings.item.held")
        XCTAssertTrue(item.waitForExistence(timeout: 15))
        XCTAssertTrue(item.label.contains("2 笔"), item.label)
        stub.devices = stub.devices.filter { !$0.revoked }
        app.terminate()
        let app2 = launch(route: "settings")
        XCTAssertTrue(el(app2, "settings.item.devices").waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(el(app2, "settings.item.held").exists, "没有就不出")
    }

    /// 退出登录：先弹 26 确认面板；「不退了」回到设置页，什么都没动；确认后走排空流程、回到登录页
    func testLogoutAsksFirst() {
        let app = launch(route: "settings", api: false)
        let logout = el(app, "settings.item.logout")
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        logout.tap()
        XCTAssertEqual(el(app, "confirm.title").label, "退出登录？")
        XCTAssertTrue(app.staticTexts["退出以后，这台手机上的账要重新登录才能看。待传的账会先传上去。"].exists)
        shot(app, "logout")
        el(app, "logout.cancel").tap()
        XCTAssertTrue(el(app, "page.settings").waitForExistence(timeout: 10), "回到设置页")
        wait("退出页也关了") { !self.el(app, "page.logout").exists }
        logout.tap()
        el(app, "logout.confirm").tap()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20), "退出到登录页")
    }

    func testMaxTextHeld() {
        stub.held = [DeviceStub.heldStockIn(id: Self.a)]
        let app = launch(route: "held", extra: S23aUITests.maxAX)
        let accept = app.buttons["held.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
        XCTAssertTrue(accept.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(accept.frame))
        let discard = app.buttons["held.discard"]
        for _ in 0..<4 where !discard.isHittable { app.swipeUp() }
        XCTAssertTrue(discard.isHittable)
        shot(app, "held-ax")
        discard.tap()
        let cancel = el(app, "held.discard.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        for _ in 0..<4 where !cancel.isHittable { el(app, "confirm.sheet").swipeUp() }
        XCTAssertTrue(cancel.isHittable)
        shot(app, "held-confirm-ax")
    }
}
