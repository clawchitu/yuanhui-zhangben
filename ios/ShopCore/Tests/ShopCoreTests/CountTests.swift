import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S26 盘点（§5.6、设计稿 12a / 12b）：键盘没有小数点；黄条「比账上少 N」；进度按本月（上海）有盘点流水的商品数算
/// （补偿行、冲销行、被撤销的、上个月的不算）；12b 只列在卖的、不是待确认的没数商品；整箱码认成这个商品；
/// 只能联网：先传完本机 outbox 再交，排空后账面版本变了先问「账上现在是 N 个」不交，交上去被拒 stale 带回新账面数，
/// 确认后带新版本重交（新 op）；「账面 2 填 1」发出去的是 counted 1 / base 2。
final class CountTests: XCTestCase, @unchecked Sendable {
    let me = uuid(0x5A1), other = uuid(0x5A2), epoch = uuid(0xE0)
    let liquor = DemoSeed.id(0x201), beer = DemoSeed.id(0x202), noodle = DemoSeed.id(0x203), cola = DemoSeed.id(0x204)
    let zhonghua = DemoSeed.id(0x205), water = DemoSeed.id(0x206)
    let today = try! CalendarDate("2026-11-26")

    func makeDB(role: Role = .family) throws -> LocalDB {
        let db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: nil)
        try db.beginSession(try LocalSession(deviceId: me, storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epoch.uuidString)
        return db
    }

    func sqlExec(_ db: LocalDB, _ sql: String, _ args: StatementArguments = []) throws {
        try db.writer.write { try $0.execute(sql: sql, arguments: args) }
    }

    // MARK: - 规则

    func testKeypadHasNoDecimalPointAndCapsDigits() {
        var t = ""
        for c in "0" { t = CountRule.append(t, digit: c) }
        XCTAssertEqual(t, "0")
        t = CountRule.append(t, digit: "3")
        XCTAssertEqual(t, "3", "前导 0 换掉")
        t = CountRule.append(t, digit: ".")
        XCTAssertEqual(t, "3", "没有小数点")
        t = CountRule.append(t, digit: "-")
        XCTAssertEqual(t, "3", "没有负号")
        for c in "123456789" { t = CountRule.append(t, digit: c) }
        XCTAssertEqual(t, "3123456", "最多 7 位（≤ 9,999,999）")
        XCTAssertEqual(CountRule.counted(t), 3_123_456)
        XCTAssertEqual(CountRule.backspace("12"), "1")
        XCTAssertNil(CountRule.counted(""))
        XCTAssertNil(CountRule.counted("1.5"))
        XCTAssertEqual(CountRule.counted("0"), 0)
    }

    func testHintAndStaleQuestion() {
        XCTAssertEqual(CountRule.hint(counted: 1, book: 2, unit: "罐"), "比账上少 1 罐，存好后按实际算")
        XCTAssertEqual(CountRule.hint(counted: 5, book: 2, unit: "罐"), "比账上多 3 罐，存好后按实际算")
        XCTAssertEqual(CountRule.hint(counted: 3, book: -2, unit: "瓶"), "比账上多 5 瓶，存好后按实际算")
        XCTAssertNil(CountRule.hint(counted: 2, book: 2, unit: "罐"))
        XCTAssertEqual(CountRule.staleQuestion(stockQty: 1, unit: "罐"), "账上现在是 1 罐，你数的还对吗")
        XCTAssertTrue(CountRule.canConfirmBook(0))
        XCTAssertFalse(CountRule.canConfirmBook(-2), "账上是负数时不能点「没错」")
    }

    func testMonthBoundsCoverWholeShanghaiMonth() {
        let (a, b) = CountRule.monthBounds(try! CalendarDate("2026-02-14"))
        XCTAssertEqual(a, "2026-02-01T00:00:00.000+08:00")
        XCTAssertTrue("2026-02-28T23:59:59.999+08:00" <= b && "2026-03-01T00:00:00.000+08:00" > b)
    }

    // MARK: - 进度和 12b

    func countEntry(_ product: UUID, at: String, seq: Int, flags: [String: Any]? = nil, voided: Bool = false,
                    reverses: UUID? = nil, qty: Int64 = 0) -> [String: Any] {
        var e: [String: Any] = ["id": UUID().uuidString.lowercased(), "seq": seq, "op_id": UUID().uuidString.lowercased(),
                                "batch_id": NSNull(), "type": "count",
                                "reverses_entry_id": reverses.map { $0.uuidString.lowercased() } ?? NSNull(),
                                "product_id": product.uuidString.lowercased(), "name_snapshot": "x", "qty_delta": qty,
                                "amount_fen": 0, "list_amount_fen": 0, "cogs_fen": 0, "value_delta_fen": 0,
                                "device_id": other.uuidString.lowercased(), "occurred_at": at,
                                "voided_at": voided ? "2026-11-20T03:00:00.000Z" : NSNull(), "rev": seq]
        if let flags { e["flags"] = flags }
        return e
    }

    func pull(_ db: LocalDB, entries: [[String: Any]], products: [[String: Any]] = [], results: [[String: Any]] = []) throws {
        try db.applySyncResponse(try SyncResponse.decode(try response(results: results, products: products, entries: entries)), sent: nil)
    }

    func testProgressCountsThisMonthsCountEntriesOnly() throws {
        let db = try makeDB()
        var p = try db.countProgress(today: today)
        XCTAssertEqual(p.counted, 0)
        XCTAssertEqual(p.remaining, 6)
        try pull(db, entries: [
            countEntry(beer, at: "2026-11-05T10:00:00.000+08:00", seq: 1),                     // 本月数过（「没错」也记一条全 0 的）
            countEntry(beer, at: "2026-11-06T10:00:00.000+08:00", seq: 2, qty: -1),            // 同一样数两次只算一种
            countEntry(cola, at: "2026-10-31T23:59:59.000+08:00", seq: 3, qty: -2),            // 上个月的不算
            countEntry(liquor, at: "2026-10-31T16:30:00.000Z", seq: 4),                       // UTC 10-31 16:30 = 上海 11-01 00:30，本月
            countEntry(zhonghua, at: "2026-11-10T10:00:00.000+08:00", seq: 5, flags: ["late_before_count": true], qty: 1), // 迟到补偿行不是人数的
            countEntry(noodle, at: "2026-11-11T10:00:00.000+08:00", seq: 6, voided: true, qty: -1), // 撤销了的不算
        ])
        p = try db.countProgress(today: today)
        XCTAssertEqual(p.counted, 2, "啤酒、二锅头")
        XCTAssertEqual(Set(p.uncounted.map(\.id)), [noodle, cola, zhonghua, water])
        XCTAssertEqual(p.uncounted.map(\.product.name), p.uncounted.map(\.product.name).sorted(), "12b 按名称排")
        XCTAssertEqual(p.uncounted.first { $0.id == water }?.stockQty, -2, "12b 写账上几个（负的照写）")
        // 12 月 1 日起重新数
        XCTAssertEqual(try db.countProgress(today: try CalendarDate("2026-12-01")).counted, 0)
        // 这次刚交成功、拉取还没带回流水的也算
        p = try db.countProgress(today: today, alsoCounted: [cola])
        XCTAssertEqual(p.counted, 3)
        XCTAssertFalse(p.uncounted.contains { $0.id == cola })
    }

    func testUncountedSkipsArchivedAndNeedsReview() throws {
        let db = try makeDB()
        try sqlExec(db, "UPDATE product SET archived = 1 WHERE id = ?", [water.uuidString])
        try sqlExec(db, "UPDATE product SET needs_review = 1 WHERE id = ?", [zhonghua.uuidString])
        let p = try db.countProgress(today: today)
        XCTAssertEqual(p.remaining, 4, "停用的、待确认的不用数")
        XCTAssertEqual(p.counted, 0)
    }

    func testCashierHasNoCount() throws {
        let db = try makeDB(role: .cashier)
        XCTAssertEqual(try db.countProgress(today: today), CountProgress(counted: 0, uncounted: []))
        XCTAssertNil(try db.countItem(barcode: "6901035600016"), "收银员手机没有账面数")
    }

    func testScanUnitOrPackBarcodeGivesBaseUnitBook() throws {
        let db = try makeDB()
        let a = try XCTUnwrap(try db.countItem(barcode: "6901035600016"))
        let b = try XCTUnwrap(try db.countItem(barcode: "6901035600023"))
        XCTAssertEqual(a, b, "整箱码也认成这个商品，按基本单位数")
        XCTAssertEqual(a.stockQty, 48)
        XCTAssertEqual(a.unit, "罐")
        XCTAssertNil(try db.countItem(barcode: "6999999999999"))
    }

    // MARK: - 只能联网：先传完、版本变了先问、stale、确认后重交

    final class FakeServer: @unchecked Sendable {
        var bodies: [[String: Any]] = []
        var reply: (([String: Any]) throws -> (Int, Data))!
        var transport: SyncEngine.Transport {
            { [self] body in
                let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                bodies.append(obj)
                return try reply(obj)
            }
        }
        var sentOps: [[String: Any]] { bodies.flatMap { $0["ops"] as? [[String: Any]] ?? [] } }
    }

    func response(results: [[String: Any]], products: [[String: Any]] = [], entries: [[String: Any]] = []) throws -> Data {
        let obj: [String: Any] = [
            "results": results,
            "changes": ["products": products, "barcodes": [], "removed": [], "entries": entries, "batches": [], "lots": []],
            "cursors": ["catalog": 10, "ledger": 10], "has_more": ["catalog": false, "ledger": false],
            "total_products": 6, "server_time": "2026-11-26T10:00:00.000Z", "epoch": epoch.uuidString.lowercased(), "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func productJSON(_ id: UUID, name: String, unit: String, stock: Int, ver: Int, rev: Int) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "name": name, "base_unit": unit, "price_fen": 600, "needs_review": false,
         "track_expiry": false, "image_ver": 0, "archived": false, "rev": rev,
         "private": ["stock_qty": stock, "stock_value_fen": stock * 420, "last_cost_fen": 420, "cost_known": true, "stock_ver": ver,
                     "low_at": NSNull(), "expiry_warn_days": 7, "shelf_life_months": NSNull()] as [String: Any]]
    }

    func allApplied(_ obj: [String: Any]) -> [[String: Any]] {
        (obj["ops"] as? [[String: Any]] ?? []).map { ["id": $0["id"]!, "status": "applied"] }
    }

    func testOnlineCountDrainsFirstAsksOnStaleAndResubmitsNewOp() throws {
        let db = try makeDB()
        // 账上 2 罐（版本 5）
        try sqlExec(db, "UPDATE product_private SET stock_qty = 2, stock_value_fen = 840, stock_ver = 5 WHERE product_id = ?", [beer.uuidString])
        let seen = try XCTUnwrap(try db.countItem(beer))
        XCTAssertEqual(seen.stockQty, 2)
        XCTAssertInvalid(try db.enqueue(Op(payload: try CountPayload(entryId: UUID(), productId: beer, countedQty: 1, baseQty: 2, baseVer: 5))),
                         "盘点不进离线队列")
        // 本机还有一笔没传的卖出（别的商品）
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6925303770013")))
        try db.recordSale(b)
        let srv = FakeServer()
        let engine = SyncEngine(db: db, appBuild: 1, transport: srv.transport)
        // 交之前没传完：submitOnline 不发请求
        let early = try db.countOp(productId: beer, counted: 1, expectedVer: 5)
        guard case .submit(let earlyOp) = early else { return XCTFail("\(early)") }
        XCTAssertThrowsError(try engine.submitOnline(earlyOp)) { XCTAssertEqual($0 as? OnlineSubmitError, .outboxNotDrained(1)) }
        XCTAssertTrue(srv.bodies.isEmpty)

        // 1. 先传完本机 outbox；这一趟拉下来另一台手机刚卖的 1 罐：账上 1、版本 6
        srv.reply = { try (200, self.response(results: self.allApplied($0),
                                               products: [self.productJSON(self.beer, name: "青岛啤酒 500ml", unit: "罐", stock: 1, ver: 6, rev: 20)])) }
        try engine.drainForOnline()
        XCTAssertEqual(srv.sentOps.map { $0["type"] as? String }, ["sale_batch"], "先传完本机的卖出")
        // 2. 版本不是人看到的那一版：不交，先问「账上现在是 1 罐」
        guard case .stale(1, 6) = try db.countOp(productId: beer, counted: 1, expectedVer: seen.stockVer) else { return XCTFail() }
        XCTAssertEqual(srv.sentOps.count, 1, "没交")

        // 3. 人说「对」：带版本 6 交；服务器这时又有一笔（账上 0、版本 7）→ stale 带回
        guard case .submit(let op1) = try db.countOp(productId: beer, counted: 1, expectedVer: 6) else { return XCTFail() }
        let p1 = try XCTUnwrap(op1.payload as? CountPayload)
        XCTAssertEqual([p1.countedQty, p1.baseQty, p1.baseVer], [1, 1, 6])
        srv.reply = { obj in
            let id = (obj["ops"] as? [[String: Any]])?.first?["id"]
            let res: [[String: Any]] = id.map { [["id": $0, "status": "rejected", "code": "stale", "current": ["stock_qty": 0, "stock_ver": 7]]] } ?? []
            return try (200, self.response(results: res, products: [self.productJSON(self.beer, name: "青岛啤酒 500ml", unit: "罐", stock: 0, ver: 7, rev: 21)]))
        }
        XCTAssertEqual(try engine.submitOnline(op1), .stale(stockQty: 0, stockVer: 7))
        XCTAssertTrue(try db.allOutbox().allSatisfy { $0.type != .count }, "盘点不进 outbox")
        XCTAssertEqual(try db.countProgress(today: today).counted, 0, "被拒的不算数过")

        // 4. 再确认：新 op、新 entry，带版本 7 交，成功；拉取带回这条盘点流水 → 已数 1 种
        guard case .submit(let op2) = try db.countOp(productId: beer, counted: 1, expectedVer: 7) else { return XCTFail() }
        let p2 = try XCTUnwrap(op2.payload as? CountPayload)
        XCTAssertNotEqual(op2.id, op1.id)
        XCTAssertNotEqual(p2.entryId, p1.entryId)
        srv.reply = { obj in
            try (200, self.response(results: self.allApplied(obj),
                                    products: [self.productJSON(self.beer, name: "青岛啤酒 500ml", unit: "罐", stock: 1, ver: 8, rev: 22)],
                                    entries: [self.countEntry(self.beer, at: "2026-11-26T19:48:00.000+08:00", seq: 30, qty: 1)]))
        }
        XCTAssertEqual(try engine.submitOnline(op2), .applied)
        let sent = try XCTUnwrap(srv.sentOps.last)
        XCTAssertEqual(sent["type"] as? String, "count")
        XCTAssertEqual((sent["id"] as? String)?.lowercased(), op2.id.uuidString.lowercased())
        let payload = try XCTUnwrap(sent["payload"] as? [String: Any])
        XCTAssertEqual(payload["counted_qty"] as? Int, 1)
        XCTAssertEqual(payload["base_qty"] as? Int, 0)
        XCTAssertEqual(payload["base_ver"] as? Int, 7)
        XCTAssertEqual(try db.countItem(beer)?.stockQty, 1)
        XCTAssertEqual(try db.countProgress(today: today).counted, 1)
    }

    /// 验收「账面 2 填 1」：发出去的就是 counted 1、base 2、当时的版本；服务器记盘亏 1 个（server 测试 + 联调核对）
    func testBookTwoCountedOneSendsCountedOneBaseTwo() throws {
        let db = try makeDB()
        try sqlExec(db, "UPDATE product_private SET stock_qty = 2, stock_ver = 9 WHERE product_id = ?", [cola.uuidString])
        guard case .submit(let op) = try db.countOp(productId: cola, counted: 1, expectedVer: 9) else { return XCTFail() }
        XCTAssertEqual(op.type, .count)
        let p = try XCTUnwrap(op.payload as? CountPayload)
        XCTAssertEqual(p.productId, cola)
        XCTAssertEqual([p.countedQty, p.baseQty, p.baseVer], [1, 2, 9])
        guard case .gone = try db.countOp(productId: UUID(), counted: 1, expectedVer: 1) else { return XCTFail() }
    }
}
