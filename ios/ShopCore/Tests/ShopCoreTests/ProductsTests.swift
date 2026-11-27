import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S25：商品列表的筛选和计数（快没货与 09 同一条件，§14 S07-6）、改商品（本地先改 + `product_edit`，单件码不存价）、
/// 删整箱码、待确认补全只能联网（`submitOnline`：先传完 outbox、`stale` 带回账面数、同一 op 重交幂等）、
/// 自动建的待确认商品（卖价 0、没条码）先发 `product_edit` + `barcode_link` 再补全（§14 S05-9）。
final class ProductsTests: XCTestCase, @unchecked Sendable {
    let me = uuid(0x5A1), epoch = uuid(0xE0)
    let beer = DemoSeed.id(0x202), cola = DemoSeed.id(0x204), water = DemoSeed.id(0x206), zhonghua = DemoSeed.id(0x205)
    let today = try! CalendarDate("2026-11-20")

    func makeDB(role: Role = .family) throws -> LocalDB {
        let db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: nil)
        try db.beginSession(try LocalSession(deviceId: me, storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epoch.uuidString)
        return db
    }

    func item(_ db: LocalDB, _ id: UUID, today: CalendarDate? = nil) throws -> ProductListItem {
        try XCTUnwrap(try db.productList(today: today ?? self.today).items.first { $0.id == id })
    }

    func sqlExec(_ db: LocalDB, _ sql: String, _ args: StatementArguments = []) throws {
        try db.writer.write { try $0.execute(sql: sql, arguments: args) }
    }

    // MARK: - 列表和筛选

    func testCountsAndFiltersOnDemoSeed() throws {
        let db = try makeDB()
        let (items, c) = try db.productList(today: today)
        XCTAssertEqual(c.all, 6)
        // 批次 11-25 到期、提前 7 天 → 11-18 起提醒：青岛、康师傅、可乐
        XCTAssertEqual(c.expiring, 3)
        XCTAssertEqual(Set(items.filter { $0.matches(.expiring) }.map(\.product.name)), ["青岛啤酒 500ml", "康师傅红烧牛肉面", "可口可乐 330ml"])
        // 快没货（提醒线 3）：农夫山泉 -2（≤ 0 照列，显示「没货了」）
        XCTAssertEqual(c.lowStock, 1)
        XCTAssertEqual(items.filter { $0.matches(.lowStock) }.map(\.id), [water])
        // 没进价：农夫山泉（进价没填）
        XCTAssertEqual(c.noCost, 1)
        XCTAssertEqual(c.needsReview, 0)
        XCTAssertEqual(try item(db, beer).earliestExpiry?.description, "2026-11-25")
        XCTAssertEqual(try item(db, beer).packs.map(\.barcode), ["6901035600023"], "只列整件码")
        XCTAssertEqual(try item(db, beer).unitCostFen, Fen(420))
        XCTAssertNil(try item(db, water).unitCostFen, "进价没填不显示平均进价")
        // 11-10：还没到提醒的日子
        XCTAssertEqual(try db.productList(today: try CalendarDate("2026-11-10")).counts.expiring, 0)
    }

    /// 快没货与 `reports/today.ts` 同一条件（§14 S07-6）：没停用、不是待确认、`stock_ver > 0`、`stock_qty ≤ COALESCE(low_at, low_stock_default)`
    func testLowStockSameConditionAsServer() throws {
        let db = try makeDB()
        // 中华 6、商品自己的提醒线 3 → 不算；提醒线改成没设、店里默认 7 → 算
        XCTAssertFalse(try item(db, zhonghua).lowStock)
        try sqlExec(db, "UPDATE product_private SET low_at = NULL WHERE product_id = ?", [zhonghua.uuidString])
        XCTAssertFalse(try item(db, zhonghua).lowStock, "没设提醒线、店里默认 3：6 > 3")
        try db.setMeta(.lowStockDefault, "7")
        XCTAssertTrue(try item(db, zhonghua).lowStock, "店里默认 7：6 ≤ 7")
        // 刚好等于提醒线也算
        try db.setMeta(.lowStockDefault, "6")
        XCTAssertTrue(try item(db, zhonghua).lowStock)
        // stock_ver = 0（库存从没动过）不算
        try sqlExec(db, "UPDATE product_private SET stock_ver = 0 WHERE product_id = ?", [zhonghua.uuidString])
        XCTAssertFalse(try item(db, zhonghua).lowStock)
        // 待确认不算（只在「待确认」里提醒）
        try sqlExec(db, "UPDATE product SET needs_review = 1 WHERE id = ?", [water.uuidString])
        XCTAssertFalse(try item(db, water).lowStock)
        XCTAssertTrue(try item(db, water).matches(.needsReview))
        XCTAssertFalse(try item(db, water).matches(.noCost), "待确认的不重复算进「没进价」")
        // 停用的不算，也不进「全部」
        try sqlExec(db, "UPDATE product SET needs_review = 0, archived = 1 WHERE id = ?", [water.uuidString])
        let (items, c) = try db.productList(today: today)
        XCTAssertFalse(try item(db, water).lowStock)
        XCTAssertEqual(c.all, 5)
        XCTAssertEqual(items.last?.id, water, "停用的排在最后")
    }

    /// 本机没传的卖出也算进快没货（显示库存 = 基线 + 本机增减）
    func testLowStockCountsPendingSales() throws {
        let db = try makeDB()
        try db.setMeta(.lowStockDefault, "3")
        try sqlExec(db, "UPDATE product_private SET stock_qty = 4, stock_value_fen = 0, cost_known = 0, stock_ver = 0 WHERE product_id = ?",
                    [zhonghua.uuidString])
        XCTAssertFalse(try item(db, zhonghua).lowStock)
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901028075862")))
        try db.recordSale(b)
        let it = try item(db, zhonghua)
        XCTAssertEqual(it.stockQty, 3)
        XCTAssertTrue(it.lowStock, "卖了一包 → 3 ≤ 3；库存动过（传上去 stock_ver 就 +1）")
    }

    /// 快过期：「过几天再提醒」没到日子不提醒；没剩的批次不算
    func testExpiringRespectsSnoozeAndQty() throws {
        let db = try makeDB()
        try sqlExec(db, "UPDATE lot SET snoozed_until = '2026-11-22' WHERE product_id = ?", [beer.uuidString])
        XCTAssertFalse(try item(db, beer).expiring)
        XCTAssertTrue(try item(db, beer, today: try CalendarDate("2026-11-22")).expiring, "到了那天又提醒")
        try sqlExec(db, "UPDATE lot SET qty_left = 0 WHERE product_id = ?", [cola.uuidString])
        XCTAssertFalse(try item(db, cola).expiring)
        XCTAssertNil(try item(db, cola).earliestExpiry)
        XCTAssertTrue(LocalDB.shouldRemind(today: try CalendarDate("2026-03-01"), expiry: try CalendarDate("2026-03-05"), qtyLeft: 1,
                                           snoozedUntil: nil, warnDays: 4), "跨月：3-05 减 4 天是 3-01")
        XCTAssertFalse(LocalDB.shouldRemind(today: try CalendarDate("2026-02-28"), expiry: try CalendarDate("2026-03-05"), qtyLeft: 1,
                                            snoozedUntil: nil, warnDays: 4))
    }

    func testSearchByNameOrBarcodePrefix() throws {
        let db = try makeDB()
        let (items, _) = try db.productList(today: today)
        let codes = try db.barcodesByProduct()
        func find(_ q: String) -> [String] {
            items.filter { LocalDB.searchMatches($0, query: q, barcodes: codes[$0.id] ?? []) }.map(\.product.name)
        }
        XCTAssertEqual(find("可乐"), ["可口可乐 330ml"])
        XCTAssertEqual(find("6901035600023"), ["青岛啤酒 500ml"], "扫整箱码也找得到")
        XCTAssertEqual(find(" ").count, 6)
    }

    // MARK: - 改商品

    /// 改卖价：本地马上用新价（扫任一单件码、按名称找），整箱码有自己的价就不变；op 只带改了的字段；旧流水的名称、价不变
    func testEditPriceUsesNewPriceEverywhereLocally() throws {
        let db = try makeDB()
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        let old = try db.recordSale(b)
        try db.editProduct(try ProductEditPayload(productId: beer, name: .set("青岛啤酒 经典 500ml"), priceFen: .set(Fen(650))))
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.unitPrice(), Fen(650), "单件码读商品的卖价")
        XCTAssertEqual(try db.searchByName("经典").first?.unitPrice(), Fen(650))
        XCTAssertEqual(try db.lookup(barcode: "6901035600023")?.unitPrice(), Fen(13200), "整箱码的价不变")
        // 两个单件码的商品：两个码都用新价
        let noodle = DemoSeed.id(0x203)
        try db.editProduct(try ProductEditPayload(productId: noodle, priceFen: .set(Fen(500))))
        XCTAssertEqual(try db.lookup(barcode: "6902514300011")?.unitPrice(), Fen(500))
        XCTAssertEqual(try db.lookup(barcode: "6902514300035")?.unitPrice(), Fen(500))
        // 旧流水保持原名称原价
        let row = try XCTUnwrap(try db.writer.read { try Row.fetchOne($0, sql: "SELECT name_snapshot, amount_fen FROM entry WHERE batch_id = ?",
                                                                       arguments: [old.batchId.uuidString]) })
        XCTAssertEqual(row["name_snapshot"] as String, "青岛啤酒 500ml")
        XCTAssertEqual(row["amount_fen"] as Int64, 600)
        // op：只带改了的字段（逐字段后写者赢，S04-4）
        let edits = try db.pendingOps().filter { $0.type == .productEdit }
        XCTAssertEqual(edits.count, 2)
        let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: edits[0].opJSON) as? [String: Any])?["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["product_id", "name", "price_fen"])
        XCTAssertEqual(payload["price_fen"] as? Int, 650)
    }

    func testEditPrivateFieldsAndArchive() throws {
        let db = try makeDB()
        try db.editProduct(try ProductEditPayload(productId: beer, lowAt: .set(6), trackExpiry: .set(true), expiryWarnDays: .set(5),
                                                  shelfLifeMonths: .set(6)))
        let d = try XCTUnwrap(try db.productDetail(beer))
        XCTAssertEqual(d.private?.lowAt, 6)
        XCTAssertEqual(d.private?.expiryWarnDays, 5)
        XCTAssertEqual(d.private?.shelfLifeMonths, 6)
        XCTAssertEqual(d.packs.map(\.barcode), ["6901035600023"])
        // 不卖了：按名称找不到，扫码照样认得出（界面提示已停用、照卖）
        try db.editProduct(try ProductEditPayload(productId: beer, archived: .set(true)))
        XCTAssertTrue(try db.searchByName("青岛").isEmpty)
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.product.archived, true)
        XCTAssertFalse(try item(db, beer).matches(.all))
        let last = try XCTUnwrap(try db.pendingOps().last)
        let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: last.opJSON) as? [String: Any])?["payload"] as? [String: Any])
        XCTAssertEqual(payload["archived"] as? Bool, true)
        // 改基本单位：单件码的单位名跟着改，整件码不动（S04-5）
        try db.editProduct(try ProductEditPayload(productId: beer, baseUnit: .set("听")))
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.barcode.unitName, "听")
        XCTAssertEqual(try db.lookup(barcode: "6901035600023")?.barcode.unitName, "箱")
    }

    func testCashierCannotEditOrUnlink() throws {
        let db = try makeDB(role: .cashier)
        XCTAssertInvalid(try db.editProduct(try ProductEditPayload(productId: beer, priceFen: .set(Fen(1)))))
        XCTAssertInvalid(try db.unlinkPack(barcode: "6901035600023", productId: beer))
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.unitPrice(), Fen(600), "被拒什么都不写")
        XCTAssertTrue(try db.pendingOps().isEmpty)
    }

    func testUnlinkPack() throws {
        let db = try makeDB()
        XCTAssertInvalid(try db.unlinkPack(barcode: "6901035600016", productId: beer), "单件码不在这里删")
        XCTAssertInvalid(try db.unlinkPack(barcode: "6901035600023", productId: cola), "码不在这个商品上")
        try db.unlinkPack(barcode: "6901035600023", productId: beer)
        XCTAssertNil(try db.lookup(barcode: "6901035600023"))
        let op = try XCTUnwrap(try db.pendingOps().last)
        XCTAssertEqual(op.type, .barcodeUnlink)
        let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: op.opJSON) as? [String: Any])?["payload"] as? [String: Any])
        XCTAssertEqual(payload["barcode"] as? String, "6901035600023")
    }

    // MARK: - 联网补全

    /// 假服务器：记下每个请求；`reply` 按请求体给响应
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

    func response(results: [[String: Any]], products: [[String: Any]] = [], lowStockDefault: Int? = 3,
                  deletePending: String? = nil) throws -> Data {
        var store: [String: Any] = ["name": "元辉烟酒店"]
        if let lowStockDefault { store["low_stock_default"] = lowStockDefault }
        var obj: [String: Any] = [
            "results": results,
            "changes": ["products": products, "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": 10, "ledger": 10], "has_more": ["catalog": false, "ledger": false],
            "total_products": 6, "server_time": "2026-11-20T10:00:00.000Z", "epoch": epoch.uuidString.lowercased(), "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": store]
        if let deletePending { obj["delete_pending_until"] = deletePending }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func allApplied(_ obj: [String: Any]) -> [[String: Any]] {
        (obj["ops"] as? [[String: Any]] ?? []).map { ["id": $0["id"]!, "status": "applied"] }
    }

    func reviewProduct(_ id: UUID, needsReview: Bool, price: Int, stockVer: Int, stock: Int = 0, name: String = "白象 老母鸡汤面") -> [String: Any] {
        ["id": id.uuidString.lowercased(), "name": name, "base_unit": "个", "price_fen": price, "needs_review": needsReview,
         "track_expiry": false, "image_ver": 0, "archived": false, "rev": 20,
         "private": ["stock_qty": stock, "stock_value_fen": 0, "last_cost_fen": NSNull(), "cost_known": false, "stock_ver": stockVer,
                     "low_at": NSNull(), "expiry_warn_days": 7, "shelf_life_months": NSNull()] as [String: Any]]
    }

    func review(_ id: UUID, counted: Int64, cost: Int64, baseVer: Int64, baseQty: Int64? = nil) throws -> Op {
        Op(payload: try ProductReviewCompletePayload(entryId: UUID(), productId: id, unitCostFen: Fen(cost), countedQty: counted,
                                                     baseVer: baseVer, baseQty: baseQty))
    }

    func testLowStockDefaultComesFromSyncResponse() throws {
        let db = try makeDB()
        let srv = FakeServer()
        srv.reply = { try (200, self.response(results: self.allApplied($0), lowStockDefault: 7)) }
        try SyncEngine(db: db, appBuild: 1, transport: srv.transport).sync()
        XCTAssertEqual(try db.lowStockDefault(), 7)
        srv.reply = { try (200, self.response(results: self.allApplied($0), lowStockDefault: nil)) }
        try SyncEngine(db: db, appBuild: 1, transport: srv.transport).sync()
        XCTAssertEqual(try db.lowStockDefault(), 7, "旧服务器不带这个键：不动")
        // 换身份清投影时一起清（属于投影）
        try db.endSession()
        XCTAssertNil(try db.meta(.lowStockDefault))
    }

    /// 只能联网的 op 不进 outbox；交之前先把本机的账传完；`stale` 带回账面数，带新版本重交成功；同一 op 重交字节不变
    func testSubmitOnlineDrainsOutboxThenHandlesStale() throws {
        let db = try makeDB()
        let pid = UUID()
        try sqlExec(db, "INSERT INTO product (id, name, base_unit, price_fen, needs_review) VALUES (?, '白象 老母鸡汤面', '个', 450, 1)",
                    [pid.uuidString])
        try sqlExec(db, "INSERT INTO product_private (product_id, stock_qty, stock_value_fen, cost_known, stock_ver, expiry_warn_days) VALUES (?, -1, 0, 0, 1, 7)",
                    [pid.uuidString])
        XCTAssertInvalid(try db.enqueue(try review(pid, counted: 8, cost: 320, baseVer: 1)), "补全不进离线队列")
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b)
        let srv = FakeServer()
        let engine = SyncEngine(db: db, appBuild: 1, transport: srv.transport)
        srv.reply = { try (200, self.response(results: self.allApplied($0))) }
        try engine.drainForOnline()
        XCTAssertEqual(try db.syncStatus().pendingCount, 0)
        XCTAssertEqual(srv.sentOps.map { $0["type"] as? String }, ["sale_batch"])
        // 另一台手机在这期间又卖了 2 个：账面 -3、版本 2 → stale
        let first = try review(pid, counted: 8, cost: 320, baseVer: 1, baseQty: -1)
        srv.reply = { obj in
            let id = (obj["ops"] as? [[String: Any]])?.first?["id"]
            let res: [[String: Any]] = id.map { [["id": $0, "status": "rejected", "code": "stale", "current": ["stock_qty": -3, "stock_ver": 2]]] } ?? []
            return try (200, self.response(results: res, products: [self.reviewProduct(pid, needsReview: true, price: 450, stockVer: 2, stock: -3)]))
        }
        XCTAssertEqual(try engine.submitOnline(first), .stale(stockQty: -3, stockVer: 2))
        XCTAssertEqual(try db.productPrivate(pid)?.stockVer, 2, "同一响应的拉取带回新账面")
        XCTAssertTrue(try db.allOutbox().allSatisfy { $0.type != .productReviewComplete }, "补全不进 outbox")
        // 带新版本确认后成功：待确认数减一
        let second = try review(pid, counted: 8, cost: 320, baseVer: 2, baseQty: -3)
        srv.reply = { obj in
            try (200, self.response(results: self.allApplied(obj), products: [self.reviewProduct(pid, needsReview: false, price: 450, stockVer: 3, stock: 8)]))
        }
        let before = try db.productList(today: today).counts.needsReview
        XCTAssertEqual(try engine.submitOnline(second), .applied)
        XCTAssertEqual(before - 1, try db.productList(today: today).counts.needsReview)
        // 同一 op 重交：字节不变（服务器按 id 回第一次的结果）
        let n = srv.bodies.count
        _ = try engine.submitOnline(second)
        let sent = srv.bodies[n]["ops"] as? [[String: Any]]
        XCTAssertEqual((sent?.first?["id"] as? String)?.lowercased(), second.id.uuidString.lowercased())
        let payload = try XCTUnwrap(sent?.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["base_ver"] as? Int, 2)
        XCTAssertEqual(payload["unit_cost_fen"] as? Int, 320)
        XCTAssertEqual(payload["counted_qty"] as? Int, 8)
    }

    /// 传不完本机的账不交（交了版本也对不上）；注销期间不交；收银员交不了
    func testSubmitOnlineRefusals() throws {
        let db = try makeDB()
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b)
        let srv = FakeServer()
        let engine = SyncEngine(db: db, appBuild: 1, transport: srv.transport)
        srv.reply = { _ in (503, Data()) }
        XCTAssertThrowsError(try engine.drainForOnline())
        XCTAssertThrowsError(try engine.submitOnline(try review(beer, counted: 1, cost: 0, baseVer: 1))) {
            XCTAssertEqual($0 as? OnlineSubmitError, .outboxNotDrained(1), "没传完不交，一个请求都不发")
        }
        srv.reply = { _ in try (200, self.response(results: [], deletePending: "2026-11-27T00:00:00.000Z")) }
        XCTAssertThrowsError(try engine.drainForOnline()) { XCTAssertEqual($0 as? OnlineSubmitError, .deletePending) }
        XCTAssertThrowsError(try engine.submitOnline(try review(beer, counted: 1, cost: 0, baseVer: 1))) {
            XCTAssertEqual($0 as? OnlineSubmitError, .deletePending)
        }
        let cashier = try makeDB(role: .cashier)
        XCTAssertInvalid(try SyncEngine(db: cashier, appBuild: 1, transport: srv.transport).submitOnline(try review(beer, counted: 1, cost: 0, baseVer: 1)))
    }

    /// §14 S05-9：卖出引用未知商品时服务器自动建的待确认商品（卖价 0、没条码）。22b 先发 `product_edit`（卖价）和
    /// `barcode_link`（单件码，不带价），传完再交 `product_review_complete`；不发 `product_upsert`
    func testAutoCreatedReviewProductSendsEditAndLinkBeforeReview() throws {
        let db = try makeDB()
        let srv = FakeServer()
        let pid = UUID()
        srv.reply = { obj in try (200, self.response(results: self.allApplied(obj),
                                                     products: [self.reviewProduct(pid, needsReview: true, price: 0, stockVer: 1, stock: -2, name: "没写名称 …0001")])) }
        let engine = SyncEngine(db: db, appBuild: 1, transport: srv.transport)
        try engine.sync()
        let d = try XCTUnwrap(try db.productDetail(pid))
        XCTAssertTrue(d.product.needsReview)
        XCTAssertEqual(d.product.priceFen, .zero)
        XCTAssertFalse(d.hasUnitBarcode)
        try db.editProduct(try ProductEditPayload(productId: pid, name: .set("白象 老母鸡汤面"), priceFen: .set(Fen(450))))
        let link = try db.linkUnitBarcode("6920000000017", productId: pid)
        XCTAssertNil(try db.lookup(barcode: "6920000000017")?.barcode.packPriceFen, "单件码不带价")
        XCTAssertEqual(try db.lookup(barcode: "6920000000017")?.unitPrice(), Fen(450))
        srv.reply = { obj in try (200, self.response(results: self.allApplied(obj))) }
        try engine.drainForOnline()
        XCTAssertEqual(try db.outboxStatus(link)?.status, .applied)
        let ver = try XCTUnwrap(try db.productPrivate(pid)).stockVer
        _ = try engine.submitOnline(try review(pid, counted: 8, cost: 320, baseVer: ver, baseQty: -2))
        XCTAssertEqual(srv.sentOps.map { $0["type"] as? String }, ["product_edit", "barcode_link", "product_review_complete"])
        XCTAssertFalse(srv.sentOps.contains { ($0["type"] as? String) == "product_upsert" })
        let linkPayload = try XCTUnwrap(srv.sentOps[1]["payload"] as? [String: Any])
        XCTAssertEqual(linkPayload["pack_qty"] as? Int, 1)
        XCTAssertNil(linkPayload["pack_price_fen"], "单件码不带价")
        // 码已经登记过 → 拒，什么都不写
        XCTAssertInvalid(try db.linkUnitBarcode("6901035600016", productId: pid))
    }
}
