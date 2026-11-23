import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S22a：按字节拆批、一个响应一个事务（中途注入故障整批回滚）、被拒后临时库存纠正、注销期间停推、
/// 批次头冲突更新不级联删明细、本机临时冲销行按 op_id 换成服务器行。
final class SyncEngineTests: XCTestCase, @unchecked Sendable {
    let me = uuid(0x5A1), epoch = uuid(0xE0)
    struct Boom: Error {}

    func makeDB(fault: (@Sendable (LocalDBFaultPoint) throws -> Void)? = nil) throws -> LocalDB {
        let db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: fault)
        try db.beginSession(try LocalSession(deviceId: me, storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epoch.uuidString)
        return db
    }

    func sell(_ db: LocalDB) throws -> (UUID, UUID) {
        var b = Basket()
        let conv = try XCTUnwrap(try db.lookup(barcode: "6901035600016"))
        try b.add(conv)
        let batch = UUID()
        try db.recordSale(b, batchId: batch, at: Date())
        return (batch, conv.product.id)
    }

    /// 假服务器的响应：每个推上来的 op 给同一个结果
    func response(ops: [[String: Any]], status: String = "applied", code: String? = nil, cursor: Int = 10,
                  products: [[String: Any]] = [], batches: [[String: Any]] = [], entries: [[String: Any]] = [],
                  deletePending: String? = nil, moreCatalog: Bool = false, barcodes: [[String: Any]] = [],
                  moreLedger: Bool = false) throws -> Data {
        var results: [[String: Any]] = []
        for o in ops { var r: [String: Any] = ["id": o["id"]!, "status": status]; if let code { r["code"] = code }; results.append(r) }
        var obj: [String: Any] = [
            "results": deletePending == nil ? results : [],
            "changes": ["products": products, "barcodes": barcodes, "removed": [], "entries": entries, "batches": batches, "lots": []],
            "cursors": ["catalog": cursor, "ledger": cursor], "has_more": ["catalog": moreCatalog, "ledger": moreLedger],
            "total_products": 312, "server_time": "2026-11-22T10:00:00.000Z", "epoch": epoch.uuidString.lowercased(), "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
        if let deletePending { obj["delete_pending_until"] = deletePending }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func ops(_ body: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
    }

    func productJSON(_ id: UUID, stock: Int64? = nil, name: String = "测试商品") -> [String: Any] {
        var p: [String: Any] = ["id": id.uuidString.lowercased(), "name": name, "base_unit": "瓶", "price_fen": 500,
                                "needs_review": false, "track_expiry": false, "image_ver": 0, "archived": false, "rev": 3]
        if let stock {
            p["private"] = ["stock_qty": stock, "stock_value_fen": 0, "last_cost_fen": NSNull(), "cost_known": false,
                            "stock_ver": 9, "low_at": NSNull(), "expiry_warn_days": 7, "shelf_life_months": NSNull()] as [String: Any]
        }
        return p
    }

    /// PR #36 评审必须修 1：商品流按 rev 分页，卖过货的商品 rev 大、它的条码 rev 小，条码可能先于商品到达。
    /// 第一页 520 个条码（商品都不在本机）、第二页才是这 520 样商品：两页都要能提交、游标前进，商品到了条码就能扫。
    func testBarcodesBeforeTheirProductsAcrossPages() throws {
        let db = try makeDB()
        let ids = (0..<520).map { _ in UUID() }
        let codes = ids.enumerated().map { (i, id) -> [String: Any] in
            ["barcode": String(format: "69990%08d", i), "product_id": id.uuidString.lowercased(), "pack_qty": 1,
             "unit_name": "瓶", "pack_price_fen": NSNull(), "rev": i + 1]
        }
        let page = Box(0), codesBox = Box(codes)
        let engine = SyncEngine(db: db, appBuild: 1) { body in
            page.value += 1
            if page.value == 1 { return (200, try self.response(ops: self.ops(body), cursor: 520, moreCatalog: true, barcodes: codesBox.value)) }
            return (200, try self.response(ops: self.ops(body), cursor: 1040, products: ids.map { self.productJSON($0) }))
        }
        let r1 = try SyncResponse.decode(try response(ops: [], cursor: 520, moreCatalog: true, barcodes: codes))
        try db.applySyncResponse(r1, sent: nil)
        XCTAssertEqual(try db.meta(.catalogCursor), "520", "条码先到的一页也能提交，游标前进")
        XCTAssertNil(try db.lookup(barcode: "6999000000000"), "商品没到之前扫不到")
        XCTAssertNil(try db.meta(.catalogDone))
        page.value = 1
        try engine.sync()
        XCTAssertEqual(try db.meta(.catalogDone), "1")
        XCTAssertEqual(try db.meta(.catalogCursor), "1040")
        XCTAssertEqual(try XCTUnwrap(try db.lookup(barcode: "6999000000519")).product.id, ids[519], "商品到了条码就挂上")
        XCTAssertEqual(try db.count("barcode_pending"), 0)
    }

    /// PR #36 评审必须修 2（Codex 原场景）：库存 10、卖 1 显示 9；确认响应不带这样商品（新基线在商品流后页）时仍显示 9，
    /// 后页带来新基线 9 后还是 9，不错回 10、也不重复扣成 8
    func testAppliedDeltaHeldUntilNewBaselineArrives() throws {
        let db = try makeDB()
        let (_, pid) = try sell(db)
        let shown = try XCTUnwrap(try db.displayStock(pid))
        let base = shown.baselineQty
        let batch = try XCTUnwrap(try db.nextPushBatch())
        let r1 = try SyncResponse.decode(try response(ops: ops(try db.syncRequestBody(batch, appBuild: 1)), cursor: 5, moreCatalog: true))
        try db.applySyncResponse(r1, sent: batch)
        XCTAssertEqual(try db.syncStatus().pendingCount, 0)
        XCTAssertEqual(try db.displayStock(pid)?.qty, shown.qty, "已确认但新基线未到：不错回原库存")
        let r2 = try SyncResponse.decode(try response(ops: [], cursor: 9, products: [productJSON(pid, stock: base - 1)], moreCatalog: true))
        try db.applySyncResponse(r2, sent: nil)
        XCTAssertEqual(try db.displayStock(pid)?.qty, shown.qty, "新基线到了：增减放掉，不重复扣")
        XCTAssertEqual(try db.count("effect_hold"), 0)
    }

    /// 本机流水行原样变成服务器行的 JSON（seq、voided_at 由调用方给）
    func serverEntries(_ db: LocalDB, where cond: String, seq: Int, voidedAt: String? = nil) throws -> [[String: Any]] {
        try db.writer.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM entry WHERE \(cond) ORDER BY rowid").enumerated().map { (i, r) in
                ["id": r["id"] as String, "seq": seq + i, "op_id": (r["op_id"] as String?) ?? NSNull(),
                 "batch_id": (r["batch_id"] as String?) ?? NSNull(), "type": r["type"] as String,
                 "reverses_entry_id": (r["reverses_entry_id"] as String?) ?? NSNull(), "product_id": r["product_id"] as String,
                 "name_snapshot": r["name_snapshot"] as String, "qty_delta": r["qty_delta"] as Int64,
                 "amount_fen": r["amount_fen"] as Int64, "list_amount_fen": r["list_amount_fen"] as Int64,
                 "device_id": r["device_id"] as String, "occurred_at": r["occurred_at"] as String,
                 "voided_at": voidedAt ?? NSNull(), "rev": seq + i] as [String: Any]
            }
        }
    }

    /// PR #36 评审必须修 3（Codex 原场景）：卖出的确认请求在途时撤销，旧响应带回「没撤」的原行不能冲掉本机撤销；
    /// 否则同一笔又能撤一次，库存 10 → 11
    func testInFlightLocalVoidSurvivesStaleResponse() throws {
        let db = try makeDB()
        let (batchId, pid) = try sell(db)
        let start = try XCTUnwrap(try db.displayStock(pid)).qty + 1
        let batch = try XCTUnwrap(try db.nextPushBatch())
        let stale = try serverEntries(db, where: "batch_id = '\(batchId.uuidString)'", seq: 1)
        guard case .voided = try db.void(.batch(batchId)) else { return XCTFail() }   // 请求在途时撤销
        let r = try SyncResponse.decode(try response(ops: ops(try db.syncRequestBody(batch, appBuild: 1)),
                                                      products: [productJSON(pid, stock: start - 1)], entries: stale))
        try db.applySyncResponse(r, sent: batch)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entry WHERE batch_id = ? AND reverses_entry_id IS NULL AND voided_at IS NULL", arguments: [batchId.uuidString]) }, 0,
                       "本机在途撤销优先")
        XCTAssertEqual(try db.void(.batch(batchId)), .alreadyVoided, "不能再撤一次")
        XCTAssertEqual(try db.displayStock(pid)?.qty, start, "库存回到卖前，不多加")
    }

    func testBatchesSplitByBytes() throws {
        let db = try makeDB()
        for _ in 0..<5 { _ = try sell(db) }
        let one = try XCTUnwrap(try db.nextPushBatch()).items[0].opJSON.count
        XCTAssertEqual(try XCTUnwrap(try db.nextPushBatch(maxBytes: one * 2 + 2)).items.count, 2, "按字节截断")
        XCTAssertEqual(try XCTUnwrap(try db.nextPushBatch(maxBytes: 1)).items.count, 1, "单个 op 总放得下")
        let st = try SyncEngine(db: db, appBuild: 1) { body in (200, try self.response(ops: self.ops(body))) }.sync()
        XCTAssertEqual(st.pendingCount, 0)
        XCTAssertEqual(try db.allOutbox().filter { $0.status == .applied }.count, 5)
    }

    func testMidCommitFaultRollsBackWholeResponse() throws {
        let armed = Box(true)
        let db = try makeDB { p in if p == .midSyncCommit, armed.value { throw Boom() } }
        let (_, pid) = try sell(db)
        let before = try XCTUnwrap(try db.displayStock(pid))
        let engine = SyncEngine(db: db, appBuild: 1) { body in
            let o = self.ops(body)
            let priv: [String: Any] = ["stock_qty": before.baselineQty - 1, "stock_value_fen": 0, "last_cost_fen": NSNull(),
                                       "cost_known": false, "stock_ver": 9, "low_at": NSNull(), "expiry_warn_days": 7,
                                       "shelf_life_months": NSNull(), "last_count_at": NSNull()]
            let p: [String: Any] = ["id": pid.uuidString.lowercased(), "name": "青岛啤酒", "base_unit": "瓶", "price_fen": 500,
                                    "needs_review": false, "track_expiry": false, "image_ver": 0, "archived": false, "rev": 3, "private": priv]
            return (200, try self.response(ops: o, products: [p]))
        }
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try db.syncStatus().pendingCount, 1, "结果没记上：op 仍待传")
        XCTAssertNil(try db.meta(.ledgerCursor), "游标没推进")
        XCTAssertEqual(try db.displayStock(pid), before, "基线和待传增减都没变，不重复扣")
        armed.value = false
        try engine.sync()
        let after = try XCTUnwrap(try db.displayStock(pid))
        XCTAssertEqual(after.pendingDelta, 0)
        XCTAssertEqual(after.qty, before.qty, "同一个事务：基线换成服务器的、待传增减同时消失，不重复扣")
        XCTAssertEqual(try db.meta(.ledgerCursor), "10")
    }

    func testRejectedCorrectsStockAndDeletePendingStopsPush() throws {
        let db = try makeDB()
        let (_, pid) = try sell(db)
        let base = try XCTUnwrap(try db.displayStock(pid)).baselineQty
        var e = SyncEngine(db: db, appBuild: 1) { body in (200, try self.response(ops: self.ops(body), status: "rejected", code: "forbidden")) }
        try e.sync()
        XCTAssertEqual(try db.displayStock(pid)?.qty, base, "被拒的 op 的临时增减消失")
        XCTAssertEqual(try db.allOutbox().first?.rejectCode, "forbidden")
        _ = try sell(db)
        let pushed = Box<[Int]>([])
        e = SyncEngine(db: db, appBuild: 1) { body in
            pushed.value.append(self.ops(body).count)
            return (200, try self.response(ops: self.ops(body), deletePending: "2026-11-29T10:00:00.000Z"))
        }
        try e.sync()
        try e.sync()
        XCTAssertEqual(pushed.value, [1, 0], "看到 delete_pending_until 后停推")
        XCTAssertEqual(try db.syncStatus().pendingCount, 1, "op 留在 outbox")
        XCTAssertNotNil(try db.syncStatus().deletePendingUntil)
    }

    func testBatchUpsertKeepsLinesAndLocalReversalReplacedByOpId() throws {
        let db = try makeDB()
        let (batch, _) = try sell(db)
        let n0 = try db.count("entry")
        try db.applyPulledLedger(batches: [PulledBatch(id: batch, deviceId: me, listTotalFen: 500, paidTotalFen: 500, occurredAt: Date())], entries: [])
        XCTAssertEqual(try db.count("entry"), n0, "批次头冲突更新，不级联删明细（PR #34 Codex 可选 1）")
        guard case .voided(let vop, _) = try db.void(.batch(batch)) else { return XCTFail() }
        XCTAssertEqual(try db.count("entry"), n0 + 1)
        let line = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Date())).first?.lines.first)
        let serverRev: [String: Any] = ["id": UUID().uuidString, "seq": 7, "op_id": vop.uuidString, "batch_id": batch.uuidString,
            "type": "sale", "reverses_entry_id": line.id.uuidString, "product_id": line.productId.uuidString,
            "name_snapshot": line.name, "qty_delta": 1, "amount_fen": -line.amountFen, "list_amount_fen": -line.listAmountFen,
            "device_id": me.uuidString, "occurred_at": "2026-11-22T10:00:00Z", "voided_at": NSNull(), "rev": 11]
        let r = try SyncResponse.decode(try response(ops: [], entries: [serverRev]))
        try db.applySyncResponse(r, sent: nil)
        XCTAssertEqual(try db.count("entry"), n0 + 1, "本机临时冲销行换成服务器那一行，不重复")
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entry WHERE seq = 7") }, 1)
    }

    /// PR #36 已知偏差：remap 只改了本机商品 / 条码 / 流水，outbox 里待传 op 仍挂旧商品 id。
    /// 服务器按 product_aliases 认旧 id（server/src/sync/aliases.ts，每种带 product_id 的 op 都先解析别名），不会记错商品或拒收；
    /// 本机显示库存把旧 id 上的待传增减并到赢家（product_remap），remap 到确认之间不少扣。待传 op 的字节原样重发。
    func testRemapKeepsPendingDeltaOnWinnerAndResendsOriginalBytes() throws {
        let db = try makeDB()
        let conv = try db.registerProduct(try NewProduct(barcode: "6924743919211", name: "乐事薯片 原味 70g", priceFen: Fen(750)))
        let old = conv.product.id
        var b = Basket()
        try b.add(conv); try b.add(conv)
        try db.recordSale(b, batchId: UUID(), at: Date())
        let pending = try db.pendingOps()
        let saleBytes = try XCTUnwrap(pending.first { $0.type == .saleBatch }).opJSON
        // 服务器上这个条码早被另一台登记了：赢家 W，库存基线 10。只回登记那一条的结果（卖出那批还没到）
        let winner = UUID()
        let priv: [String: Any] = ["stock_qty": 10, "stock_value_fen": 0, "last_cost_fen": NSNull(), "cost_known": false,
                                   "stock_ver": 1, "low_at": NSNull(), "expiry_warn_days": 7, "shelf_life_months": NSNull(),
                                   "last_count_at": NSNull()]
        let w: [String: Any] = ["id": winner.uuidString.lowercased(), "name": "乐事薯片", "base_unit": "包", "price_fen": 800,
                                "needs_review": false, "track_expiry": false, "image_ver": 0, "archived": false, "rev": 2, "private": priv]
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try response(ops: [], products: [w])) as? [String: Any])
        obj["results"] = [["id": pending[0].id.uuidString.lowercased(), "status": "applied",
                           "remap": [old.uuidString.lowercased(): winner.uuidString.lowercased()]]]
        let r = try SyncResponse.decode(try JSONSerialization.data(withJSONObject: obj))
        try db.applySyncResponse(r, sent: nil)
        XCTAssertEqual(try db.lookup(barcode: "6924743919211")?.product.id, winner, "本机条码改到赢家")
        XCTAssertEqual(try db.displayStock(winner), DisplayStock(baselineQty: 10, pendingDelta: -2), "旧 id 上待传的两件算在赢家上")
        let still = try XCTUnwrap(try db.pendingOps().first { $0.type == .saleBatch })
        XCTAssertEqual(still.opJSON, saleBytes, "待传 op 原样重发（服务器按别名改写到赢家并回 remap）")
        // 连锁 remap：赢家后来又成了别名，旧 id 的增减跟着走
        let w2 = UUID()
        var w2p = w; w2p["id"] = w2.uuidString.lowercased()
        var obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: try response(ops: [], products: [w2p])) as? [String: Any])
        obj2["results"] = [["id": UUID().uuidString.lowercased(), "status": "applied",
                            "remap": [winner.uuidString.lowercased(): w2.uuidString.lowercased()]]]
        try db.applySyncResponse(try SyncResponse.decode(try JSONSerialization.data(withJSONObject: obj2)), sent: nil)
        XCTAssertEqual(try db.displayStock(w2)?.pendingDelta, -2)
        // 卖出确认后增减消失，以服务器基线为准
        try db.applySyncResponse(try SyncResponse.decode(try response(ops: [["id": still.id.uuidString.lowercased()]])), sent: nil)
        XCTAssertEqual(try db.displayStock(w2)?.pendingDelta, 0)
    }

    func testRejectedCardMarkedAndServerTimeKept() throws {
        let db = try makeDB()
        _ = try sell(db)
        try SyncEngine(db: db, appBuild: 1) { body in (200, try self.response(ops: self.ops(body), status: "rejected", code: "forbidden")) }.sync()
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Date())).first)
        XCTAssertTrue(card.rejected, "被拒的这笔卡上标「没记上」")
        let st = try db.syncStatus()
        XCTAssertEqual(st.serverTimeAtSync, ISO8601DateFormatter().date(from: "2026-11-22T10:00:00Z"))
        XCTAssertNotNil(st.lastSyncAt)
    }

    func testOverdueAfterOneDay() throws {
        let db = try makeDB()
        _ = try sell(db)
        let st = try db.syncStatus()
        XCTAssertFalse(st.overdue(now: Date()))
        XCTAssertTrue(st.overdue(now: Date().addingTimeInterval(25 * 3600)), "超过一天没传")
        XCTAssertEqual(st.overdueCount, 0)
        XCTAssertEqual(try db.syncStatus(now: Date().addingTimeInterval(25 * 3600)).overdueCount, 1)
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

extension DatabaseWriter {
    func makeSnapshotOrRead() throws -> DatabaseQueue { self as! DatabaseQueue }
}
