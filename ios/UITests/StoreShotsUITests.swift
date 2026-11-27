import Foundation
import XCTest

/// S30 商店截图（`make store-shots` → `scripts/store-shots.sh`）：用审核号登录本机服务端上的「演示小店」（`create-demo-store.ts` 现种的），
/// 只点界面，截 6 张：首页、卖出（篮子里三样）、进货（填好数量和进价）、看账（本月）、记的账、快过期。
///   TEST_RUNNER_YH_SHOTS_BASE / _USER / _PASSWORD   本机服务端地址、审核号和密码（脚本现生成，不写文件）
///   TEST_RUNNER_YH_SHOTS_DIR                        截图写到哪个目录（宿主机路径），文件名 <序号>-<页面>.png
/// 截图里不许出现烟、酒、「烟酒店」字样和真实包装图：演示店的商品本来就没有烟酒、不带图（首字），脚本截完还要人工逐张看（§10）。
@MainActor
final class StoreShotsUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_SHOTS_DIR"] == nil, "只在 scripts/store-shots.sh 里跑（设 TEST_RUNNER_YH_SHOTS_DIR）")
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func tap(_ e: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: 20), "找不到 \(what)", file: file, line: line)
        wait("\(what) 可点", timeout: 20, file: file, line: line) { e.isEnabled && e.isHittable }
        e.tap()
    }

    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    private func manualCode(_ app: XCUIApplication, _ code: String) {
        tap(app.buttons["scanner.manual"], "手输条码")
        XCTAssertTrue(el(app, "manual.keypad").waitForExistence(timeout: 10))
        keys(app, code)
        let pick = app.buttons["manual.pick"]
        wait("\(code) 自动选中") { pick.isEnabled }
        pick.tap()
    }

    private func backHome(_ app: XCUIApplication) {
        for _ in 0..<4 where !el(app, "page.home").exists {
            let back = app.navigationBars.buttons.firstMatch
            if back.exists && back.isHittable { back.tap() } else { app.buttons["返回"].firstMatch.tap() }
            _ = el(app, "page.home").waitForExistence(timeout: 3)
        }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 10))
    }

    private func syncLabel(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "syncStatus").allElementsBoundByIndex.map(\.label).joined(separator: " ")
    }

    private func shot(_ name: String) throws {
        // 等动画、转圈停下来
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["YH_SHOTS_DIR"]))
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        print("STORE-SHOT \(name)")
    }

    /// 演示店里的商品条码（server/src/demo/seed.ts：店内码 21 段），由脚本传进来：可乐、薯片、纸巾、矿泉水
    private var codes: [String] { (env["YH_SHOTS_CODES"] ?? "").split(separator: ",").map(String.init) }

    func testStoreScreenshots() throws {
        let user = try XCTUnwrap(env["YH_SHOTS_USER"]), password = try XCTUnwrap(env["YH_SHOTS_PASSWORD"])
        XCTAssertGreaterThanOrEqual(codes.count, 4, "要 4 个演示店条码")
        let app = XCUIApplication()
        // Debug 构建：只用 -uiAPIBase 指到本机服务端（白名单允许回环 http），其余全是真实界面和真实数据
        app.launchArguments = ["-uiAPIBase", try XCTUnwrap(env["YH_SHOTS_BASE"]), "-uiFreshInstall", "-uiResetStoredAPIBase"]
        app.launch()

        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        let u = app.textFields["login.username"]
        u.tap(); u.typeText(user)
        let pw = app.secureTextFields["login.password"]
        pw.tap(); pw.typeText(password)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(el(app, "page.onboarding").waitForExistence(timeout: 60), "登录、首次同步完进起名页")
        tap(app.buttons["onboarding.done"], "起好了")
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 20))
        wait("已同步（现在「\(syncLabel(app))」）", timeout: 60) { syncLabel(app).contains("已同步") }
        try shot("1-home")

        // 卖出：三样，停在结算前
        tap(el(app, "home.sell"), "卖出")
        for c in codes.prefix(3) { manualCode(app, c) }
        wait("一共 3 件") { el(app, "sell.itemCount").label == "一共 3 件" }
        try shot("2-sell")
        backHome(app)

        // 进货：一样，填 2 箱 / 个、进价，停在确认前
        tap(el(app, "home.stockIn"), "进货")
        manualCode(app, codes[3])
        tap(el(app, "stockIn.qty"), "填数量")
        keys(app, "12")
        tap(el(app, "stockIn.cost"), "填进价")
        keys(app, "1.2")
        tap(app.buttons["stockIn.hideKeypad"], "收起")
        try shot("3-stockin")
        backHome(app)

        // 看账：本月
        tap(el(app, "home.reports"), "看账")
        tap(el(app, "reports.tab.month"), "本月")
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 20))
        try shot("4-reports")
        backHome(app)

        // 记的账
        tap(el(app, "home.records"), "记的账")
        XCTAssertTrue(el(app, "records.card.0").waitForExistence(timeout: 20) || el(app, "records.tab.earlier").exists)
        if !el(app, "records.card.0").exists { tap(el(app, "records.tab.earlier"), "更早") }
        XCTAssertTrue(el(app, "records.card.0").waitForExistence(timeout: 20))
        try shot("5-records")
        backHome(app)

        // 快过期（演示店种了一个 3 天后到期和一个已过期的批次）
        let expiring = el(app, "home.banner.expiring")
        if expiring.waitForExistence(timeout: 5) { expiring.tap() } else { tap(el(app, "home.expiry"), "快过期") }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        try shot("6-expiry")
    }
}
