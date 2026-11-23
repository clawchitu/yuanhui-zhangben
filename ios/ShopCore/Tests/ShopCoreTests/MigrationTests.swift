import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// PR #36 新加的本机表（v3-sync 的 product_remap、v4 的 barcode_pending / effect_hold）：main 上的老版本（迁移到 v2-records）
/// 已有本地库升上来，迁移要能跑、老数据不丢、新表能用。老库这样造：用当前代码记好账，再退回 v2-records 的结构，
/// 并和一个只迁到 v2-records 的空库比对表结构完全一致（证明就是老版本的库）。
final class MigrationTests: XCTestCase {
    func schema(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")
    }

    func testUpgradeFromV2RecordsKeepsDataAndNewTablesWork() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yh-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("local.sqlite").path
        let me = uuid(0x5A1)
        // 1. 老版本里的库：登录、铺货、卖一笔（待传）、再卖一笔并确认
        do {
            let db = try LocalDB(path: path)
            try db.beginSession(try LocalSession(deviceId: me, storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                                 storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
            try DemoSeed.install(into: db)
            for _ in 0..<2 {
                var b = Basket()
                try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
                try db.recordSale(b, at: Date())
            }
            let first = try XCTUnwrap(try db.pendingOps().first)
            try db.recordResults([try OpResult(id: first.id, status: .applied, code: nil, raw: nil)], storeId: DemoSeed.storeId)
        }
        let old = try DatabaseQueue(path: path)
        try old.write { db in
            try db.execute(sql: """
                DROP TABLE effect_hold; DROP TABLE barcode_pending; DROP TABLE product_remap;
                ALTER TABLE session DROP COLUMN epoch; ALTER TABLE session DROP COLUMN logout_pending;
                ALTER TABLE session DROP COLUMN revoked;
                DELETE FROM grdb_migrations WHERE identifier IN ('v3-sync', 'v4-sync-pending-barcode', 'v5-identity');
                """)
        }
        let v2 = try DatabaseQueue()
        var m = LocalSchema.migrator()
        try m.migrate(v2, upTo: "v2-records")
        XCTAssertEqual(try old.read(schema), try v2.read(schema), "退回后就是 v2-records 的库")
        let before = try old.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry")!, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM barcode")!)
        }
        try old.close()

        // 2. 新版本打开：迁移跑完，老数据都在，外键检查干净
        let db = try LocalDB(path: path)
        let after = try db.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry")!, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM barcode")!)
        }
        XCTAssertTrue(before == after, "老数据不丢")
        XCTAssertTrue(try db.writer.read { try LocalSchema.migrator().hasCompletedMigrations($0) })
        XCTAssertEqual(try db.writer.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.count, 0)
        XCTAssertEqual(try db.syncStatus().pendingCount, 1, "待传的那笔还在")
        let pid = try XCTUnwrap(try db.lookup(barcode: "6901035600016")).product.id
        let shown = try XCTUnwrap(try db.displayStock(pid))

        // 3. 新表能用：确认待传那笔、商品流还有后页（effect_hold）；条码先于商品到（barcode_pending）
        let late = UUID()
        let pending = try XCTUnwrap(try db.nextPushBatch())
        let json: [String: Any] = [
            "results": [["id": pending.items[0].id.uuidString.lowercased(), "status": "applied"]],
            "changes": ["products": [], "barcodes": [["barcode": "6999000000001", "product_id": late.uuidString.lowercased(), "pack_qty": 1,
                                                      "unit_name": "瓶", "pack_price_fen": NSNull(), "rev": 1]],
                        "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": 5, "ledger": 5], "has_more": ["catalog": true, "ledger": false], "total_products": 312,
            "server_time": "2026-11-22T10:00:00.000Z", "epoch": UUID().uuidString.lowercased(), "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
        try db.applySyncResponse(try SyncResponse.decode(try JSONSerialization.data(withJSONObject: json)), sent: pending)
        XCTAssertEqual(try db.syncStatus().pendingCount, 0)
        XCTAssertEqual(try db.displayStock(pid)?.qty, shown.qty, "确认后基线没到，增减留着（effect_hold）")
        XCTAssertEqual(try db.count("effect_hold"), 1)
        XCTAssertEqual(try db.count("barcode_pending"), 1)
        XCTAssertNil(try db.lookup(barcode: "6999000000001"))
    }
}
