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
                  deletePending: String? = nil, moreCatalog: Bool = false) throws -> Data {
        var results: [[String: Any]] = []
        for o in ops { var r: [String: Any] = ["id": o["id"]!, "status": status]; if let code { r["code"] = code }; results.append(r) }
        var obj: [String: Any] = [
            "results": deletePending == nil ? results : [],
            "changes": ["products": products, "barcodes": [], "removed": [], "entries": entries, "batches": batches, "lots": []],
            "cursors": ["catalog": cursor, "ledger": cursor], "has_more": ["catalog": moreCatalog, "ledger": false],
            "total_products": 312, "server_time": "2026-11-22T10:00:00.000Z", "epoch": epoch.uuidString.lowercased(), "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
        if let deletePending { obj["delete_pending_until"] = deletePending }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func ops(_ body: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
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

    func testOverdueAfterOneDay() throws {
        let db = try makeDB()
        _ = try sell(db)
        let st = try db.syncStatus()
        XCTAssertFalse(st.overdue(now: Date()))
        XCTAssertTrue(st.overdue(now: Date().addingTimeInterval(25 * 3600)), "超过一天没传")
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

extension DatabaseWriter {
    func makeSnapshotOrRead() throws -> DatabaseQueue { self as! DatabaseQueue }
}
