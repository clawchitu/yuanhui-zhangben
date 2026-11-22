import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S19 进货（06a / 06b / 06c）的状态与动作（不碰界面）。蓝卡上的数由 ShopCore 算，这里核对显示文字和记进去的 op。
@MainActor
final class S19Tests: XCTestCase {
    static let colaPack = "6925303770020", cola = "6925303770013", carton = "6901028075879", beerPack = "6901035600023"
    static let erguotou = "6901234500011", newCode = "6924743919211", packCode = "6925303770099"

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "S19Tests-\(UUID().uuidString)")
    }

    private func makeDB(_ role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    private func model(_ db: LocalDB) throws -> StockInModel {
        StockInModel(db: db, today: try CalendarDate("2026-11-21"), defaults: defaults)
    }

    private func type(_ m: StockInModel, _ s: String) {
        for c in s { m.key(c == "." ? .dot : .digit(c.wholeNumberValue!)) }
    }

    private func scan(_ m: StockInModel, _ code: String) -> ScanOutcome { m.handle(Scan(code: code, source: .gun)) }

    private func lastStockIn(_ db: LocalDB) throws -> [String: Any] {
        let item = try XCTUnwrap(try db.allOutbox().last { $0.type == .stockIn })
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: item.opJSON) as? [String: Any])
        return try XCTUnwrap(obj["payload"] as? [String: Any])
    }

    /// 06a：可乐整箱码，5 箱 × ¥48 → 「一共 ¥240.00 / 入账 120 罐，每罐进价 ¥2.00」，标签随单位变
    func testColaCaseBlueCard() throws {
        let db = try makeDB()
        let m = try model(db)
        XCTAssertEqual(scan(m, Self.colaPack), .known)
        XCTAssertEqual(m.qtyLabel, "进了几箱")
        XCTAssertEqual(m.costLabel, "每箱多少钱")
        XCTAssertEqual(m.packBadge, "整箱码　1 箱 = 24 罐")
        XCTAssertEqual(m.cardSubtitle, "单罐卖 ¥3.00　店里还有 30 罐")
        XCTAssertEqual(m.active, .qty)
        XCTAssertFalse(m.keypadShowsDot, "数量键盘没有小数点")
        type(m, "5")
        m.key(.dot)
        XCTAssertEqual(m.qtyText, "5", "数量里按点没用")
        m.focus(.cost)
        XCTAssertTrue(m.keypadShowsDot)
        type(m, "48")
        XCTAssertEqual(m.totalText, "¥240.00")
        XCTAssertEqual(m.entryLine, "入账 120 罐，每罐进价 ¥2.00")
        // 演示：30 罐、货值 ¥60.00 → (6000 + 24000) / 150 = ¥2.00
        XCTAssertEqual(m.averageLine, "加上原来的，平均进价 ¥2.00")
        XCTAssertTrue(m.commit())
        let p = try lastStockIn(db)
        XCTAssertEqual(p["pack_count"] as? Int, 5)
        XCTAssertEqual(p["pack_qty"] as? Int, 24)
        XCTAssertEqual(p["unit_cost_fen"] as? Int, 4800)
        XCTAssertEqual(try db.displayStock(try XCTUnwrap(db.lookup(barcode: Self.cola)).product.id)?.qty, 150)
        XCTAssertNil(m.conversion, "记好后清空，接着扫下一样")
        XCTAssertEqual(m.notice, .saved("可口可乐 330ml 5 箱"))
        XCTAssertEqual(m.pendingCount, 1)
    }

    /// 标签随单位变：条 / 瓶
    func testLabelsFollowUnit() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.carton)
        XCTAssertEqual(m.qtyLabel, "进了几条")
        XCTAssertEqual(m.costLabel, "每条多少钱")
        _ = scan(m, Self.erguotou)
        XCTAssertEqual(m.qtyLabel, "进了几瓶")
        XCTAssertEqual(m.costLabel, "每瓶多少钱")
        XCTAssertNil(m.packBadge, "单件码没有整箱签")
    }

    /// 5 条 × ¥400、原有 6 包 → 临时库存 56 包；outbox 的 stock_in 带件数和每条单价
    func testCartonTempStockAndOutbox() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.carton)
        type(m, "5")
        m.focus(.cost)
        type(m, "400")
        XCTAssertEqual(m.preview?.newStockQty, 56)
        XCTAssertEqual(m.entryLine, "入账 50 包，每包进价 ¥40.00")
        XCTAssertTrue(m.commit())
        let p = try lastStockIn(db)
        XCTAssertEqual(p["pack_count"] as? Int, 5)
        XCTAssertEqual(p["unit_cost_fen"] as? Int, 40000)
        XCTAssertEqual(p["pack_qty"] as? Int, 10)
        XCTAssertEqual(try db.displayStock(try XCTUnwrap(db.lookup(barcode: Self.carton)).product.id)?.qty, 56)
    }

    /// 06b：生产日期 2026-11-12 + 6 个月 = 2027-05-12；年月日填满自动跳格；保质期月数记住上次的值
    func testExpiryProducedPlusMonths() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.beerPack)   // 青岛啤酒整箱：管保质期
        XCTAssertTrue(m.showsExpiry)
        XCTAssertEqual(m.year, "2026", "年份默认今年")
        XCTAssertEqual(m.monthsText, "12", "没记过：用商品上的保质期月数")
        type(m, "3"); m.focus(.cost); type(m, "55")
        m.focus(.year)
        XCTAssertFalse(m.keypadShowsDot)
        m.key(.delete); m.key(.delete); m.key(.delete); m.key(.delete)
        type(m, "2026")
        XCTAssertEqual(m.active, .month, "年填满 4 位跳到月")
        type(m, "11")
        XCTAssertEqual(m.active, .day, "月填满两位跳到日")
        type(m, "12")
        XCTAssertEqual(m.day, "12")
        m.focus(.months)
        m.key(.delete); m.key(.delete)
        type(m, "6")
        m.doneEditing()
        XCTAssertNil(m.active)
        XCTAssertEqual(m.computedExpiry?.description, "2027-05-12")
        XCTAssertTrue(m.commit())
        XCTAssertEqual(try lastStockIn(db)["expiry_date"] as? String, "2027-05-12")
        // 下一次进同一样：保质期月数是上次的 6
        _ = scan(m, Self.beerPack)
        XCTAssertEqual(m.monthsText, "6")
    }

    /// 两种填法可切换：直接填到期日；「不知道，先不填」不带到期日；不管保质期的商品没有到期日区
    func testExpiryDirectAndUnknown() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.erguotou)
        XCTAssertFalse(m.showsExpiry)
        _ = scan(m, Self.beerPack)
        m.expiryMode = .direct
        type(m, "1"); m.focus(.cost); type(m, "100")
        m.fillDate("2027-03-01")
        XCTAssertEqual(try m.expiryDate()?.description, "2027-03-01")
        XCTAssertNil(m.computedExpiry, "直接填时不算")
        m.expiryUnknown = true
        XCTAssertNil(try m.expiryDate())
        m.expiryUnknown = false
        m.fillDate("2027-02-30")
        XCTAssertFalse(m.commit(), "不是真的日子不记")
        XCTAssertTrue(m.notice?.isError ?? false)
        XCTAssertEqual(try db.allOutbox().filter { $0.type == .stockIn }.count, 0)
    }

    /// 进价填 0：先问一句，确认了才记
    func testZeroCostNeedsConfirmation() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.erguotou)
        type(m, "2"); m.focus(.cost); type(m, "0")
        XCTAssertTrue(m.canCommit)
        XCTAssertFalse(m.commit())
        XCTAssertTrue(m.confirmZeroCost)
        XCTAssertEqual(try db.allOutbox().filter { $0.type == .stockIn }.count, 0)
        m.cancelZeroCost()
        XCTAssertFalse(m.confirmZeroCost)
        XCTAssertFalse(m.commit())
        XCTAssertTrue(m.commit(confirmedZero: true))
        XCTAssertEqual(try lastStockIn(db)["unit_cost_fen"] as? Int, 0)
    }

    /// 超上限：件数、入账数、总价都拦（§5.0）
    func testLimits() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.colaPack)
        type(m, "999999")
        XCTAssertEqual(m.problem, "一次最多进 99999 箱")
        XCTAssertFalse(m.canCommit)
        m.fill(qty: "99999")
        m.focus(.cost); type(m, "1")
        XCTAssertNil(m.problem, "99999 箱 × 24 罐没超入账上限")
        m.fill(qty: "2", cost: "999999.99")
        XCTAssertEqual(m.problem, "一笔最多 ¥999999.99，分两笔记")
    }

    /// 进货中遇到新商品：去登记页（从进货进来必须走完 04b）；登记好不再记进货（04b 已带库存），挂整件码则接着进这一箱
    func testNewCodeGoesToRegistration() throws {
        let db = try makeDB()
        let m = try model(db)
        XCTAssertEqual(scan(m, Self.newCode), .unknown)
        XCTAssertEqual(m.registerCode?.code, Self.newCode)
        let reg = NewProductModel(db: db, barcode: Self.newCode, mode: .stock, quick: false, canLinkPack: true)
        XCTAssertFalse(reg.offersQuickSave, "从进货进来没有「存好，接着卖」")
        XCTAssertTrue(reg.offersSecondStep)
        reg.priceKey(.digit(7))
        reg.goMore()
        reg.qtyText = "12"
        reg.cost = YuanInput("5.2")
        let conv = try XCTUnwrap(reg.saveMore())
        m.finishRegistration(.registered(conv, quick: false))
        XCTAssertNil(m.registerCode)
        XCTAssertNil(m.conversion)
        XCTAssertEqual(m.notice, .registered(conv.product.name))
        // 05：新的整箱码挂到可乐上 → 直接接着进货
        _ = scan(m, Self.packCode)
        let link = LinkPackModel(db: db, barcode: Self.packCode, mode: .stock,
                                 product: try XCTUnwrap(db.lookup(barcode: Self.cola)).product)
        link.key(.digit(2)); link.key(.digit(4))
        m.finishRegistration(.linked(try XCTUnwrap(link.save())))
        XCTAssertEqual(m.packBadge, "整箱码　1 箱 = 24 罐")
    }

    /// PR #31 Fable 必须改 1 / §14 S19-1：本机有没上传的库存变动时，蓝卡不显示「加上原来的，平均进价」
    /// （基线货值除以临时库存会算错：离线进 5 箱后再进 1 箱，旧代码显示 (6000 + 4800) / (150 + 24) = ¥0.62）
    func testAverageHiddenWhenStockHasPendingOps() throws {
        let db = try makeDB()
        let m = try model(db)
        _ = scan(m, Self.colaPack)
        type(m, "5"); m.focus(.cost); type(m, "48")
        XCTAssertEqual(m.averageLine, "加上原来的，平均进价 ¥2.00", "没有待传的变动：照常显示")
        XCTAssertTrue(m.commit())
        _ = scan(m, Self.colaPack)
        XCTAssertEqual(m.cardSubtitle, "单罐卖 ¥3.00　店里还有 150 罐", "临时库存照旧")
        type(m, "1"); m.focus(.cost); type(m, "48")
        XCTAssertEqual(m.totalText, "¥48.00")
        XCTAssertEqual(m.entryLine, "入账 24 罐，每罐进价 ¥2.00")
        XCTAssertNil(m.averageLine, "有待传的进货：不显示预计平均")
        // 卖出（待传）后再进货也一样
        let db2 = try makeDB()
        let colaId = try XCTUnwrap(db2.lookup(barcode: Self.cola)).product.id
        let sell = SellModel(db: db2)
        _ = sell.handle(Scan(code: Self.cola, source: .gun))
        XCTAssertTrue(sell.commit())
        XCTAssertNotEqual(try XCTUnwrap(db2.displayStock(colaId)).pendingDelta, 0)
        let m2 = try model(db2)
        _ = scan(m2, Self.colaPack)
        type(m2, "1"); m2.focus(.cost); type(m2, "48")
        XCTAssertNotNil(m2.entryLine)
        XCTAssertNil(m2.averageLine)
    }

    /// PR #31 Fable 必须改 2：04b 没填数量 → 不说「库存已记上」，直接在进货页接着填这一批；填了 0 也一样；填了数量才说
    func testRegisteredWithoutQtyContinuesStockIn() throws {
        let db = try makeDB()
        for (code, qty) in [("6924743919228", ""), ("6924743919235", "0")] {
            let m = try model(db)
            XCTAssertEqual(scan(m, code), .unknown)
            let reg = NewProductModel(db: db, barcode: code, mode: .stock, quick: false, canLinkPack: true)
            reg.priceKey(.digit(7)); reg.goMore()
            reg.qtyText = qty
            let conv = try XCTUnwrap(reg.saveMore())
            m.finishRegistration(.registered(conv, quick: false))
            XCTAssertNil(m.registerCode)
            XCTAssertEqual(m.conversion?.product.id, conv.product.id, "数量\(qty.isEmpty ? "没填" : "填 0")：接着在进货页填这一批")
            XCTAssertFalse(m.notice?.text.contains("库存已记上") ?? false, "库存没记，不能说记上了")
            XCTAssertEqual(m.notice?.text, "登记好了：\(conv.product.name)，库存还没记，接着填这一批")
            XCTAssertEqual(m.cardSubtitle, "单个卖 ¥7.00　店里还有 0 个")
            type(m, "3"); m.focus(.cost); type(m, "5")
            XCTAssertTrue(m.commit())
            XCTAssertEqual(try XCTUnwrap(db.displayStock(conv.product.id)).qty, 3, "只记这一次，不重复")
        }
    }

    /// 收银员不能进货：路由进不去，本地库也拒
    func testCashierCannotStockIn() throws {
        let caps = Capabilities(role: .cashier)
        XCTAssertEqual(RouteView.content(for: .stockIn, capabilities: caps), .denied)
        XCTAssertEqual(RouteView.content(for: .stockIn, capabilities: Capabilities(role: .family)), .stockIn)
        let db = try makeDB(.cashier)
        let m = try model(db)
        _ = scan(m, Self.colaPack)
        type(m, "1"); m.focus(.cost); type(m, "48")
        XCTAssertFalse(m.commit())
        XCTAssertEqual(try db.allOutbox().filter { $0.type == .stockIn }.count, 0)
    }

    /// 页面被盖住时不收码
    func testIgnoresScansWhenCovered() throws {
        let m = try model(try makeDB())
        m.accepting = false
        XCTAssertEqual(scan(m, Self.colaPack), .ignored)
        XCTAssertNil(m.conversion)
    }

    // MARK: 从 S18 带过来的

    /// 04a 卖价填 0：先问一句（「卖价是 0 元，确定吗」）
    func testZeroSellPriceNeedsConfirmation() throws {
        let db = try makeDB()
        let reg = NewProductModel(db: db, barcode: Self.newCode, mode: .sell, quick: false, canLinkPack: true)
        reg.priceKey(.digit(0))
        XCTAssertTrue(reg.canSaveBasic)
        XCTAssertNil(reg.saveBasic())
        XCTAssertTrue(reg.confirmZeroPrice)
        XCTAssertNil(try db.lookup(barcode: Self.newCode))
        reg.priceKey(.delete); reg.priceKey(.digit(0))
        XCTAssertFalse(reg.confirmZeroPrice, "改了价钱就收回确认")
        let conv = try XCTUnwrap(reg.saveBasic(confirmedZero: true))
        XCTAssertEqual(conv.product.priceFen.raw, 0)
        // 04b 也一样
        let reg2 = NewProductModel(db: db, barcode: "6924743919228", mode: .stock, quick: false, canLinkPack: true)
        reg2.priceKey(.digit(0)); reg2.goMore()
        XCTAssertNil(reg2.saveMore())
        XCTAssertTrue(reg2.confirmZeroPrice)
        XCTAssertNotNil(reg2.saveMore(confirmedZero: true))
    }

    /// PR #31 Codex 必须改 1（丢数据）：按回车不自动删名称。合法的数字后缀、纯数字名称都原样存进去
    /// （旧代码回车就把「配件 12345678」改成「配件」、把「20261121」清空，这条在旧代码上失败）
    func testNameDigitsKeptWithoutConfirm() throws {
        let db = try makeDB()
        // ① 合法名称以数字结尾
        let reg = NewProductModel(db: db, barcode: Self.newCode, mode: .stock, quick: false, canLinkPack: true)
        reg.name = "配件 12345678"
        XCTAssertEqual(reg.submitName(), "12345678", "像条码，提示一句")
        XCTAssertNotNil(reg.nameScanNotice)
        XCTAssertEqual(reg.name, "配件 12345678", "名称一个字不动")
        reg.priceKey(.digit(5))
        XCTAssertEqual(try XCTUnwrap(reg.saveBasic()).product.name, "配件 12345678")
        // ② 纯数字名称
        let reg2 = NewProductModel(db: db, barcode: "6924743919242", mode: .stock, quick: false, canLinkPack: true)
        reg2.name = "20261121"
        XCTAssertEqual(reg2.submitName(), "20261121")
        XCTAssertEqual(reg2.name, "20261121")
        reg2.priceKey(.digit(5))
        XCTAssertEqual(try XCTUnwrap(reg2.saveBasic()).product.name, "20261121", "不会变成占位名")
        // 正常名称：不提示
        let reg3 = NewProductModel(db: db, barcode: "6924743919259", mode: .stock, quick: false, canLinkPack: true)
        reg3.name = "可乐 330ml"
        XCTAssertNil(reg3.submitName(), "正常名称不动")
        XCTAssertEqual(reg3.name, "可乐 330ml")
        XCTAssertNil(reg3.nameScanNotice)
    }

    /// ③ 扫码枪在名称后面追加了条码（§14 S19-9）：提示在名称框下，人点「是条码，去掉这串数字」才去；名称一改提示就清
    func testScannerDigitsStrippedOnConfirm() throws {
        let reg = NewProductModel(db: try makeDB(), barcode: Self.newCode, mode: .stock, quick: false, canLinkPack: true)
        reg.name = "乐事薯片6925303770013"
        XCTAssertEqual(reg.submitName(), "6925303770013")
        XCTAssertEqual(reg.name, "乐事薯片6925303770013", "没确认前不删")
        XCTAssertTrue(reg.canStripCode)
        reg.stripScannedCode()
        XCTAssertEqual(reg.name, "乐事薯片")
        XCTAssertNil(reg.nameScanNotice)
        XCTAssertFalse(reg.canStripCode)
        reg.name = "乐事薯片 原味6925303770013"
        XCTAssertNotNil(reg.submitName())
        reg.name = "乐事薯片 原味"
        XCTAssertNil(reg.nameScanNotice, "名称一改，提示就清掉")
        XCTAssertFalse(reg.canStripCode)
        reg.stripScannedCode()
        XCTAssertEqual(reg.name, "乐事薯片 原味", "提示清掉后不会再去")
    }

    /// §14 S18-3：05 底部那句带上商品名
    func testLinkPackHintNamesProduct() throws {
        let db = try makeDB()
        let link = LinkPackModel(db: db, barcode: Self.packCode, mode: .stock,
                                 product: try XCTUnwrap(db.lookup(barcode: Self.cola)).product)
        link.key(.digit(2)); link.key(.digit(4))
        XCTAssertEqual(link.conversionHint, "以后扫这个码，进货卖出都按 24 罐 可口可乐 330ml 算")
    }
}
