import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// PR #40 Fable 必须修、Codex 复审 2：相机停过再开（卖出页抹零面板、手输页、登记页返回、切后台回来；进货页填数收起相机区），
/// 镜头里还是上一件时不再记一次；换一件新码照常记。相机首个识别回调晚到（> 2.5 秒）也不重放。
/// 接的是真的 `CameraController.attach(to:)` + `ScanHub` + 页面模型，相机换成假的 runner。
@MainActor
final class CameraResumeReplayTests: XCTestCase {
    final class FakeRunner: CameraRunning {
        var onCode: ((String) -> Void)?
        func start() {}
        func stop() {}
    }

    static let beer = SellModelTests.beer, erguotou = SellModelTests.erguotou
    static let newCode = S18Tests.newCode

    private var now: TimeInterval = 1000
    private let runner = FakeRunner()
    private var hub: ScanHub!
    private var camera: CameraController!

    private func makeDB() throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    /// 和 `CameraViewfinder.CameraBox` 一样接线：相机认出的码进扫码层，每次开相机调 `cameraResumed`
    private func wire(_ handler: @escaping (Scan) -> ScanOutcome) {
        hub = ScanHub(clock: { [unowned self] in now })
        hub.handler = handler
        let permission = CameraPermission(status: { .authorized }, requester: { true })
        camera = CameraController(runner: runner, permission: permission)
        camera.attach(to: hub)
        camera.update(visible: true, sceneActive: true)
    }

    /// 相机每 0.1 秒认出一次画面里的这几个码
    private func frames(_ codes: [String], seconds: Double) {
        for _ in 0..<Int(seconds * 10) {
            for c in codes { runner.onCode?(c) }
            now += 0.1
        }
    }

    private func sell(_ registration: SellModel.Registration = .none) throws -> SellModel {
        let m = SellModel(db: try makeDB(), registration: registration)
        wire { m.handle($0) }
        return m
    }

    /// 卖出页 `covered` 变了：`accepting` 跟着变，相机暂停 / 恢复（SellView 的 `.onChange(of: covered)` 和 `paused: covered`）
    private func cover(_ m: SellModel, _ covered: Bool) {
        m.accepting = !covered
        camera.update(visible: true, sceneActive: true, paused: covered)
    }

    private func count(_ m: SellModel, _ code: String) -> Int64 {
        m.basket.lines.first { $0.barcode == code }?.packCount ?? 0
    }

    // MARK: 卖出页

    /// 扫 A → 抹零面板（相机停 5 秒）→ 确定 → 回来 A 还在镜头里：A 不加一，抹的零不作废；换 B 照收
    func testSellDiscountPanelDoesNotReplayTheCodeStillInView() throws {
        let m = try sell()
        frames([Self.beer], seconds: 1)
        XCTAssertEqual(count(m, Self.beer), 1)
        cover(m, true)
        now += 5
        try m.setPaid(300)
        cover(m, false)
        frames([Self.beer], seconds: 3)
        XCTAssertEqual(count(m, Self.beer), 1, "A 还在镜头里：不再记一次")
        XCTAssertNotNil(m.discountFen, "抹的零没被作废")
        XCTAssertNotEqual(m.notice, .paidCleared)
        frames([Self.erguotou, Self.beer], seconds: 2)
        XCTAssertEqual(count(m, Self.erguotou), 1, "新的一件照常记")
        XCTAssertEqual(count(m, Self.beer), 1, "A、B 同在画面里，A 也不重复算")
        XCTAssertEqual(m.itemCount, 2)
    }

    /// 扫 A → 手输条码页（相机停 3 秒）选 B → 回来 A 还在镜头里：只有 B 进篮子，A 不加一
    func testSellManualEntryDoesNotReplayTheCameraCode() throws {
        let m = try sell()
        frames([Self.beer], seconds: 1)
        cover(m, true)
        now += 3
        // SellView.pickManual：先关页面、恢复收码，再交手输的码
        cover(m, false)
        hub.receive(Self.erguotou, from: .manual)
        frames([Self.beer], seconds: 3)
        XCTAssertEqual(count(m, Self.beer), 1)
        XCTAssertEqual(count(m, Self.erguotou), 1)
        XCTAssertEqual(m.itemCount, 2)
    }

    /// 相机扫到没登记的 X → 登记页存好（篮里 1 件）→ 回来 X 还在镜头里：X 不变 2 件；扫 A 照收
    func testSellRegistrationReturnDoesNotReplayTheNewCode() throws {
        let m = try sell(.full)
        frames([Self.newCode], seconds: 0.5)
        XCTAssertEqual(m.registerCode?.code, Self.newCode)
        cover(m, true)
        now += 20
        let reg = NewProductModel(db: m.db, barcode: Self.newCode, mode: .sell, quick: false, canLinkPack: true)
        reg.applyLookup(.found(name: "乐事薯片 原味 70g", unit: "包"))
        for c in "7.5" { reg.priceKey(c == "." ? .dot : .digit(c.wholeNumberValue!)) }
        m.finishRegistration(.registered(try XCTUnwrap(reg.saveBasic()), quick: false))
        XCTAssertEqual(count(m, Self.newCode), 1)
        cover(m, false)
        frames([Self.newCode], seconds: 3)
        XCTAssertEqual(count(m, Self.newCode), 1, "登记好的那件还在镜头里：不变 2 件")
        frames([Self.beer], seconds: 1)
        XCTAssertEqual(count(m, Self.beer), 1)
    }

    /// 扫 A → 切后台 10 秒 → 回前台 A 还在镜头里：不加一；换 B 照收
    func testSellBackgroundAndBackDoesNotReplay() throws {
        let m = try sell()
        frames([Self.beer], seconds: 1)
        camera.update(visible: true, sceneActive: false)
        now += 10
        camera.update(visible: true, sceneActive: true)
        frames([Self.beer], seconds: 3)
        XCTAssertEqual(count(m, Self.beer), 1)
        frames([Self.erguotou], seconds: 1)
        XCTAssertEqual(count(m, Self.erguotou), 1)
    }

    /// 相机恢复后首个识别回调 4 秒才到（> 2.5 秒）：A 仍不重放；换 B 照收
    func testSellLateFirstCallbackAfterResumeDoesNotReplay() throws {
        let m = try sell()
        frames([Self.beer], seconds: 1)
        cover(m, true)
        now += 5
        cover(m, false)
        now += 4
        frames([Self.beer], seconds: 3)
        XCTAssertEqual(count(m, Self.beer), 1, "首回调晚到也不重放")
        frames([Self.erguotou], seconds: 1)
        XCTAssertEqual(count(m, Self.erguotou), 1)
    }

    /// 防重放不挡真的第二件：A 拿开满 1.5 秒再对上，照常加一
    func testSellSameItemAgainAfterLeavingTheViewCounts() throws {
        let m = try sell()
        frames([Self.beer], seconds: 1)
        cover(m, true)
        now += 5
        cover(m, false)
        frames([Self.beer], seconds: 1)
        now += CameraDeduper.defaultWindow + 0.1
        frames([Self.beer], seconds: 0.5)
        XCTAssertEqual(count(m, Self.beer), 2)
    }

    // MARK: 进货页

    static let colaPack = ScanLayoutTests.colaPack, stockErguotou = ScanLayoutTests.erguotou

    /// 进货页：A 的卡 → 填进价（相机区收起，相机停）→ 确认 → 相机再开、首回调 4 秒才到，A 还在镜头里：不重新弹卡；B 照收
    func testStockInCollapseAndLateCallbackDoesNotReplay() throws {
        let db = try makeDB()
        let m = StockInModel(db: db, today: try CalendarDate("2026-11-21"),
                             defaults: UserDefaults(suiteName: "CameraResumeReplayTests-\(UUID().uuidString)")!)
        wire { m.handle($0) }
        frames([Self.colaPack], seconds: 1)
        XCTAssertEqual(m.product?.name, "可口可乐 330ml")
        m.focus(.cost)
        camera.update(visible: true, sceneActive: true, paused: true)   // cameraCollapsed
        now += 5
        m.doneEditing()
        m.fill(cost: "25")
        XCTAssertTrue(m.commit())
        camera.update(visible: true, sceneActive: true, paused: false)
        now += 4
        frames([Self.colaPack], seconds: 3)
        XCTAssertNil(m.conversion, "确认过的那件没重新弹卡")
        frames([Self.stockErguotou], seconds: 0.5)
        XCTAssertEqual(m.product?.name, "牛栏山二锅头 500ml")
    }
}
