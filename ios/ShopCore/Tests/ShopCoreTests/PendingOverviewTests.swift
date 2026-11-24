import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// 「待传的账」面板和统一口径（只有「待传」和「没记上」两个词，全 App 一个数）
final class PendingOverviewTests: XCTestCase, @unchecked Sendable {
    let me = uuid(0x5A1), other = uuid(0x5A2), epoch = uuid(0xE0)

    func makeDB() throws -> LocalDB {
        let db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: nil)
        try db.beginSession(session(me))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epoch.uuidString)
        return db
    }

    func session(_ d: UUID) throws -> LocalSession {
        try LocalSession(deviceId: d, storeId: DemoSeed.storeId, role: .family, tokenRef: "t-\(d)", storeName: "元辉烟酒店", deviceLabel: "柜台手机")
    }

    @discardableResult
    func sell(_ db: LocalDB, at: Date = Date(), codes: [String] = ["6901035600016"]) throws -> SaleBatchPayload {
        var b = Basket()
        for c in codes { try b.add(try XCTUnwrap(try db.lookup(barcode: c))) }
        return try db.recordSale(b, at: at)
    }

    /// 假服务器：每个推上来的 op 给同一个结果
    func answer(_ db: LocalDB, status: String) throws {
        try SyncEngine(db: db, appBuild: 1) { body in
            let ops = ((try JSONSerialization.jsonObject(with: body)) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
            let obj: [String: Any] = [
                "results": ops.map { ["id": $0["id"]!, "status": status, "code": "forbidden"] },
                "changes": ["products": [], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
                "cursors": ["catalog": 1, "ledger": 1], "has_more": ["catalog": false, "ledger": false],
                "total_products": 1, "server_time": "2026-11-22T10:00:00.000Z", "epoch": self.epoch.uuidString.lowercased(), "min_build": 0,
                "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
            return (200, try JSONSerialization.data(withJSONObject: obj))
        }.sync()
    }

    func testSaleRowSaysWhatWasSold() throws {
        let db = try makeDB()
        let p = try sell(db, codes: ["6901035600016", "6901035600016"])
        let o = try db.pendingOverview()
        XCTAssertEqual(o.total, 1)
        let e = try XCTUnwrap(o.entries.first)
        XCTAssertEqual(e.kindText, "卖出")
        XCTAssertEqual(e.names.first, p.lines.first?.name)
        XCTAssertEqual(e.quantity, 2)
        XCTAssertEqual(e.unitName, "件")
        XCTAssertEqual(e.amountFen, p.paidTotalFen.raw)
    }

    func testNamesTextOneOrMany() {
        let one = PendingEntry(id: 1, occurredAt: Date(), type: .saleBatch, names: ["中华"], quantity: 1, unitName: "件", amountFen: 100, priceOnlyEdit: false)
        XCTAssertEqual(one.namesText, "中华", "只有一样不写「等 N 样」")
        let many = PendingEntry(id: 1, occurredAt: Date(), type: .saleBatch, names: ["中华", "可乐", "水"], quantity: 3, unitName: "件", amountFen: 100, priceOnlyEdit: false)
        XCTAssertEqual(many.namesText, "中华 等 3 样")
    }

    func testTimeTextTodayYesterdayEarlier() throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-11-24T12:00:00+08:00"))
        func text(_ s: String) throws -> String {
            PendingEntry(id: 1, occurredAt: try XCTUnwrap(iso.date(from: s)), type: .void, names: [], quantity: nil, unitName: nil,
                         amountFen: nil, priceOnlyEdit: false).timeText(now: now)
        }
        XCTAssertEqual(try text("2026-11-24T00:05:00+08:00"), "00:05")
        XCTAssertEqual(try text("2026-11-23T19:32:00+08:00"), "昨天 19:32")
        XCTAssertEqual(try text("2026-11-22T19:32:00+08:00"), "11月22日 19:32")
        XCTAssertEqual(try text("2026-11-23T15:59:00Z"), "昨天 23:59", "按上海时间分天")
    }

    func testRejectedNotCountedAsPending() throws {
        let db = try makeDB()
        try sell(db)
        try answer(db, status: "rejected")
        try sell(db)
        let o = try db.pendingOverview()
        XCTAssertEqual(o.total, 1, "没记上的不算待传")
        XCTAssertEqual(o.rejectedToday, 1)
        XCTAssertEqual(try db.pendingTally().total, 1)
        XCTAssertEqual(try db.syncStatus().totalPendingCount, 1)
    }

    func testAppliedLeavesTheList() throws {
        let db = try makeDB()
        try sell(db)
        try answer(db, status: "applied")
        let o = try db.pendingOverview()
        XCTAssertEqual(o.total, 0)
        XCTAssertTrue(o.entries.isEmpty)
    }

    func testHeldIsNotPending() throws {
        let db = try makeDB()
        try sell(db)
        try answer(db, status: "held")
        XCTAssertEqual(try db.pendingOverview().total, 0, "进货待确认已经有服务器结果，不算待传")
    }

    /// 恢复队列（以前登录时没传完的）算进总数和超过一天，但面板只给笔数、不列内容
    func testRecoveryQueueCountedButNotListed() throws {
        let db = try makeDB()
        let old = Date().addingTimeInterval(-2 * 86_400)
        try sell(db, at: old)
        try sell(db)
        try db.endSession(logoutPending: true)
        try db.beginSession(session(other))
        try DemoSeed.install(into: db)  // 换会话清了投影
        try sell(db)
        let o = try db.pendingOverview()
        XCTAssertEqual(o.currentCount, 1)
        XCTAssertEqual(o.recoveryCount, 2)
        XCTAssertEqual(o.total, 3, "顶栏、面板、首页一个数：含恢复队列")
        XCTAssertEqual(o.entries.count, 1, "旧会话的账不列出来")
        XCTAssertEqual(o.overdueCount, 1, "超过一天的也含恢复队列")
        let t = try db.pendingTally()
        XCTAssertEqual(t.total, 3); XCTAssertEqual(t.overdue, 1)
        let st = try db.syncStatus()
        XCTAssertEqual(st.pendingCount, 1, "引擎自己的口径仍只数当前会话")
        XCTAssertEqual(st.totalPendingCount, 3); XCTAssertEqual(st.overdueCount, 1)
    }

    func testListCappedNewestFirst() throws {
        let db = try makeDB()
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<23 { try sell(db, at: base.addingTimeInterval(Double(i))) }
        let o = try db.pendingOverview()
        XCTAssertEqual(o.entries.count, LocalDB.pendingListLimit)
        XCTAssertEqual(o.moreCount, 3, "「还有 3 笔」")
        XCTAssertGreaterThan(o.entries[0].occurredAt, o.entries[1].occurredAt, "新的在上")
    }

    func testStockInRowHasCountUnitAndTotal() throws {
        let db = try makeDB()
        let conv = try XCTUnwrap(try db.lookup(barcode: "6901035600016"))
        let p = try StockInPayload(entryId: UUID(), productId: conv.product.id, barcode: conv.barcode.barcode, packQty: conv.packQty,
                                   packCount: 3, unitCostFen: Fen(1200), expiryDate: nil)
        try db.recordStockIn(p, name: conv.product.name, unitName: conv.barcode.unitName)
        let e = try XCTUnwrap(try db.pendingOverview().entries.first)
        XCTAssertEqual(e.kindText, "进货")
        XCTAssertEqual(e.names, [conv.product.name])
        XCTAssertEqual(e.quantity, 3)
        XCTAssertEqual(e.amountFen, 3600)
    }

    func testHTTPErrorKeepsStatus() throws {
        let db = try makeDB()
        try sell(db)
        XCTAssertThrowsError(try SyncEngine(db: db, appBuild: 1) { _ in (503, Data()) }.sync()) {
            XCTAssertEqual($0 as? SyncHTTPError, SyncHTTPError(status: 503))
        }
        XCTAssertEqual(try db.pendingOverview().total, 1, "服务器忙：这笔还在待传")
    }
}
