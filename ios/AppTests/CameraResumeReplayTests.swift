import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// PR #40 相机防重放（第三轮重写 + Fable 补洞）：有效时钟 + 资格 + 一次只认一件。
/// 全部走真实路径：`CameraSession.Relay`（假输出端）逐帧交识别区内的全部码（带码制）→ `CameraController` →
/// `ScanHub.receiveFrame` → 页面模型。停相机 / 开相机走 `CameraController.update`，和页面上一样。
@MainActor
final class CameraResumeReplayTests: XCTestCase {
    // 校验位都对的 EAN-13（DemoSeed）
    static let erguotou = CameraCode("6901234500011", kind: .ean13)   // 牛栏山二锅头 ¥25
    static let cola = CameraCode("6925303770013", kind: .ean13)       // 可口可乐 330ml ¥3
    static let colaPack = CameraCode("6925303770020", kind: .ean13)   // 可乐整箱（进货）
    static let newCode = CameraCode(S18Tests.newCode, kind: .ean13)
    static let lot = CameraCode("LOT20261123A", kind: .code128)       // 包装上的批号

    private var now: TimeInterval = 1000
    private var out: CameraLifecycleTests.FakeOutput!
    private var session: CameraSession!
    private var hub: ScanHub!
    private var camera: CameraController!
    private var notices = 0
    private let rect = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75)

    private func makeDB() throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    /// 和 `CameraViewfinder.CameraBox` 一样接线（`attach(to:)`），相机是真的 `CameraSession`，只把输出端换成假的
    private func wire(_ handler: @escaping (Scan) -> ScanOutcome) {
        hub = ScanHub(clock: { [unowned self] in now })
        hub.handler = handler
        hub.onSeveralCodes = { [unowned self] in notices += 1 }
        out = CameraLifecycleTests.FakeOutput()
        session = CameraSession(testOutput: out)
        let permission = CameraPermission(status: { .authorized }, requester: { true })
        camera = CameraController(runner: session, permission: permission)
        camera.attach(to: hub)
        session.setRectOfInterest(rect)
        setCamera(paused: false)
    }

    private func flush() {
        session.waitForQueue()
        let e = expectation(description: "main")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private func setCamera(paused: Bool = false, sceneActive: Bool = true) {
        camera.update(visible: true, sceneActive: sceneActive, paused: paused)
        flush()
    }

    /// 相机每 0.1 秒交一帧：这一帧识别区里的全部码，经当前这一代的 Relay 交出
    private func frames(_ codes: [CameraCode], seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            out.relay?.deliver(codes)
            now += 0.1
        }
    }

    private func sell(_ registration: SellModel.Registration = .none) throws -> SellModel {
        let m = SellModel(db: try makeDB(), registration: registration)
        wire { m.handle($0) }
        hub.onSeveralCodes = { [unowned self] in notices += 1; m.showOneAtATime() }
        return m
    }

    /// 卖出页 `covered` 变了：`accepting` 跟着变，相机暂停 / 恢复（SellView 的 `.onChange(of: covered)` 和 `paused: covered`）
    private func cover(_ m: SellModel, _ covered: Bool) {
        m.accepting = !covered
        setCamera(paused: covered)
    }

    private func count(_ m: SellModel, _ c: CameraCode) -> Int64 {
        m.basket.lines.first { $0.barcode == c.value }?.packCount ?? 0
    }

    private func stock() throws -> StockInModel {
        let m = StockInModel(db: try makeDB(), today: try CalendarDate("2026-11-21"),
                             defaults: UserDefaults(suiteName: "CameraResumeReplayTests-\(UUID().uuidString)")!)
        wire { m.handle($0) }
        m.onCardClosed = { [unowned self] in hub.inputResumed() }   // 同 StockInView
        return m
    }

    // MARK: 负责人 + Fable 指定的五条

    /// ① A、B 已记 → 两件同框 → 抹零 → 恢复，首回调晚 2 秒 → 两码同框、帧里先后轮换 10 秒：数量、抹零都不变
    func testTwoRecordedItemsAcrossTheDiscountPanelWithALateFirstCallback() throws {
        let m = try sell()
        frames([Self.erguotou], seconds: 1)
        frames([Self.cola], seconds: 1)
        frames([Self.erguotou, Self.cola], seconds: 1)
        XCTAssertEqual(m.itemCount, 2)
        cover(m, true)
        now += 5
        try m.setPaid(2700)
        let discount = try XCTUnwrap(m.discountFen)
        cover(m, false)
        now += 2   // 首回调晚到
        for i in 0..<100 {
            out.relay?.deliver(i % 20 < 10 ? [Self.erguotou, Self.cola] : [Self.cola, Self.erguotou])
            now += 0.1
        }
        XCTAssertEqual(count(m, Self.erguotou), 1)
        XCTAssertEqual(count(m, Self.cola), 1)
        XCTAssertEqual(m.discountFen, discount, "抹零金额不变")
    }

    /// ② A 记上后一直在镜头前，识别随机断档（每次 ≤ 1.2 秒）30 秒，中间两次切后台：A 只记 1 次
    func testDroppedFramesAndBackgroundingDoNotRecordAgain() throws {
        let m = try sell()
        frames([Self.erguotou], seconds: 0.5)
        var rng = SystemRandomNumberGenerator()
        var t = 0.0
        var backgrounded = [false, false]
        while t < 30 {
            let gap = Double(Int.random(in: 1...12, using: &rng)) / 10   // 断档 0.1–1.2 秒
            now += gap; t += gap
            for (i, at) in [10.0, 20.0].enumerated() where !backgrounded[i] && t >= at {
                backgrounded[i] = true
                setCamera(sceneActive: false)
                now += 30
                setCamera(sceneActive: true)
            }
            frames([Self.erguotou], seconds: 0.2)
        }
        XCTAssertEqual(count(m, Self.erguotou), 1)
    }

    /// ③ 进货：A 的卡在时 A 挪开、C 入镜停着 → 确认 A（卡片关掉）→ C 不自动出卡；C 拿开 1.5 秒再对上才出 1 次
    func testStockInCodeThatArrivedDuringTheCardNeedsToBeRescanned() throws {
        let m = try stock()
        frames([Self.colaPack], seconds: 1)
        XCTAssertEqual(m.product?.name, "可口可乐 330ml")
        frames([Self.erguotou], seconds: 2)
        XCTAssertEqual(m.product?.name, "可口可乐 330ml", "卡片在：C 不换卡")
        m.fill(cost: "25")
        XCTAssertTrue(m.commit())
        frames([Self.erguotou], seconds: 2)
        XCTAssertNil(m.conversion, "卡片关掉后 C 还在画面里：不自动出卡")
        now += 1.6   // C 拿开 1.6 秒（有效时钟在走）
        frames([Self.erguotou], seconds: 1)
        XCTAssertEqual(m.product?.name, "牛栏山二锅头 500ml", "拿开再对上：出 1 次")
        m.fill(cost: "18")
        XCTAssertTrue(m.commit())
        frames([Self.erguotou], seconds: 3)
        XCTAssertNil(m.conversion, "已记的 C 在画面里不再弹")
    }

    /// ④ EAN 和 Code128 批号同框：EAN 记 1 次、不提示；两个不同的 EAN 同框：不记、提示「一次扫一件」
    func testBatchCode128NextToTheEANDoesNotCountButTwoEANsDo() throws {
        let m = try sell()
        frames([Self.lot, Self.erguotou, Self.erguotou], seconds: 1)   // 同一码值两个框也算一个
        XCTAssertEqual(count(m, Self.erguotou), 1)
        XCTAssertEqual(notices, 0, "批号不算一个码，不提示")
        now += 3
        frames([Self.erguotou, Self.cola], seconds: 1)
        XCTAssertEqual(m.itemCount, 1, "两个不同的 EAN 同框：不记")
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(m.notice, .oneAtATime)
    }

    /// ⑤ 暂停 60 秒不算「离开」；A 拿开满阈值（已记过的码 2.5 秒，有效时钟）再扫必进
    func testPauseDoesNotCountAsAwayAndAwayForTheThresholdAlwaysCounts() throws {
        let m = try sell()
        frames([Self.erguotou], seconds: 0.5)
        now += 1   // A 拿开 1 秒
        cover(m, true)
        now += 60
        cover(m, false)
        frames([Self.erguotou], seconds: 0.5)
        XCTAssertEqual(count(m, Self.erguotou), 1, "停的 60 秒不算离开")
        now += ScanHub.recordedWindow + 0.1   // 拿开满 2.5 秒
        frames([Self.erguotou], seconds: 0.5)
        XCTAssertEqual(count(m, Self.erguotou), 2, "拿开满阈值再扫必进")
        now += 2   // 已记过的码：拿开 2 秒不够
        frames([Self.erguotou], seconds: 0.5)
        XCTAssertEqual(count(m, Self.erguotou), 2, "已记过的码离开不满 2.5 秒：当漏帧，不重记")
    }

    // MARK: 卖出页其余恢复路径

    /// 扫 A → 手输条码页（相机停）选 B → 回来 A 还在镜头里：只有 B 进篮子
    func testSellManualEntryDoesNotReplayTheCameraCode() throws {
        let m = try sell()
        frames([Self.erguotou], seconds: 1)
        cover(m, true)
        now += 3
        cover(m, false)   // SellView.pickManual：先关页面、恢复收码，再交手输的码
        hub.receive(Self.cola.value, from: .manual)
        frames([Self.erguotou], seconds: 3)
        XCTAssertEqual(count(m, Self.erguotou), 1)
        XCTAssertEqual(count(m, Self.cola), 1)
    }

    /// 相机扫到没登记的 X → 登记页存好（篮里 1 件）→ 回来 X 还在镜头里：X 不变 2 件；换一件照收
    func testSellRegistrationReturnDoesNotReplayTheNewCode() throws {
        let m = try sell(.full)
        frames([Self.newCode], seconds: 0.5)
        XCTAssertEqual(m.registerCode?.code, Self.newCode.value)
        cover(m, true)
        now += 20
        let reg = NewProductModel(db: m.db, barcode: Self.newCode.value, mode: .sell, quick: false, canLinkPack: true)
        reg.applyLookup(.found(name: "乐事薯片 原味 70g", unit: "包"))
        for c in "7.5" { reg.priceKey(c == "." ? .dot : .digit(c.wholeNumberValue!)) }
        m.finishRegistration(.registered(try XCTUnwrap(reg.saveBasic()), quick: false))
        XCTAssertEqual(count(m, Self.newCode), 1)
        cover(m, false)
        frames([Self.newCode], seconds: 3)
        XCTAssertEqual(count(m, Self.newCode), 1, "登记好的那件还在镜头里：不变 2 件")
        frames([Self.erguotou], seconds: 1)
        XCTAssertEqual(count(m, Self.erguotou), 1)
    }

    /// 恢复后第一帧只有 B、之后 A 也单独出现：B 照记，A 不重记
    func testSellFirstCallbackAnotherCodeThenTheOldOne() throws {
        let m = try sell()
        frames([Self.erguotou], seconds: 1)
        cover(m, true)
        now += 5
        cover(m, false)
        now += 4
        frames([Self.cola], seconds: 0.1)
        frames([Self.erguotou], seconds: 1)
        XCTAssertEqual(count(m, Self.erguotou), 1)
        XCTAssertEqual(count(m, Self.cola), 1)
    }

    /// 进货：A 的卡 → 填进价（相机区收起）→ 确认 → 相机再开、首回调晚 4 秒，A 还在镜头里：不重新弹卡；B 单独出现照收
    func testStockInCollapseAndLateCallbackDoesNotReplay() throws {
        let m = try stock()
        frames([Self.colaPack], seconds: 1)
        m.focus(.cost)
        setCamera(paused: true)   // cameraCollapsed
        now += 5
        m.doneEditing()
        m.fill(cost: "25")
        XCTAssertTrue(m.commit())
        setCamera(paused: false)
        now += 4
        frames([Self.colaPack], seconds: 3)
        XCTAssertNil(m.conversion, "确认过的那件没重新弹卡")
        frames([Self.erguotou], seconds: 0.5)
        XCTAssertEqual(m.product?.name, "牛栏山二锅头 500ml")
    }
}
