import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S13 本地库与 outbox 的验收。
final class LocalDBTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("s13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    var dbPath: String { dir.appendingPathComponent("local.sqlite").path }

    static let familyStore = uuid(0xA1)
    static let otherStore = uuid(0xA2)

    func session(_ role: Role, device: Int, store: UUID = familyStore) throws -> LocalSession {
        try LocalSession(deviceId: uuid(0xD00 + device), storeId: store, role: role, tokenRef: "token.\(device)",
                         storeName: "元辉烟酒店", deviceLabel: "柜台手机")
    }

    func open(_ hook: (@Sendable (LocalDBFaultPoint) throws -> Void)? = nil) throws -> LocalDB {
        try LocalDB(path: dbPath, faultHook: hook)
    }

    /// 设计稿 03 的购物篮（¥53.50）
    func basket03(_ db: LocalDB) throws -> Basket {
        var b = Basket()
        try b.add(XCTUnwrap(db.lookup(barcode: "6901234500011")))
        for _ in 0..<4 { try b.add(XCTUnwrap(db.lookup(barcode: "6901035600016"))) }
        try b.add(XCTUnwrap(db.lookup(barcode: "6902514300011")))
        return b
    }

    // MARK: - 验收 1：1,000 个商品时条码查找 < 5 ms

    func testBarcodeLookupUnder5msWith1000Products() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        var base = CatalogBaseline()
        var codes: [String] = []
        for i in 0..<1000 {
            let p = try Product(id: uuid(0x10000 + i), name: "商品 \(i)", baseUnit: "个", priceFen: Fen(Int64(100 + i)))
            base.products.append(p)
            let single = "69" + String(format: "%011d", i)
            let pack = "70" + String(format: "%011d", i)
            base.barcodes.append(try BarcodeRecord(barcode: single, productId: p.id, unitName: "个"))
            base.barcodes.append(try BarcodeRecord(barcode: pack, productId: p.id, packQty: 12, unitName: "箱"))
            base.privates.append(try ProductPrivate(productId: p.id, stockQty: 10, stockValueFen: Fen(500), lastCostFen: Fen(50), costKnown: true))
            codes.append(contentsOf: [single, pack])
        }
        try db.applyBaseline(base)
        XCTAssertEqual(try db.count("product"), 1000)

        for c in codes.prefix(20) { _ = try db.lookup(barcode: c) }   // 预热（建读连接、载入页缓存）
        // 固定的工作负载：固定种子打乱，5 轮 × 1,000 次，2,000 个码每个至少查 2 次
        var rng = SplitMix64(seed: 0x5313)
        var workload: [String] = []
        while workload.count < 5 * 1000 { workload += codes.shuffled(using: &rng) }
        let clock = ContinuousClock()
        let n = 1000
        // 口径照 §14 S13-3：每一轮的中位数 < 5 ms；最好一轮的平均和 p99 < 5 ms；单次最慢只打印。
        // 另加一道宽松护栏：5,000 个样本合并的 p99 < 20 ms，挡住大幅退化，不用 5 ms 卡共享 CI 的偶发停顿。
        var rounds: [(avg: Duration, p50: Duration, p99: Duration, worst: Duration)] = []
        var all: [Duration] = []
        for r in 0..<5 {
            var times: [Duration] = []
            for code in workload[(r * n)..<((r + 1) * n)] {
                var found: PackConversion?
                times.append(clock.measure { found = try? db.lookup(barcode: code) })
                XCTAssertEqual(found?.barcode.barcode, code)
            }
            all += times
            times.sort()
            rounds.append((times.reduce(Duration.zero, +) / n, times[n / 2], times[n * 99 / 100], times[n - 1]))
        }
        XCTAssertNil(try db.lookup(barcode: "0000000000000"))
        for (i, r) in rounds.enumerated() {
            print("S13 条码查找 第 \(i + 1) 轮 \(n) 次：平均 \(r.avg)，中位 \(r.p50)，p99 \(r.p99)，最慢 \(r.worst)")
            XCTAssertLessThan(r.p50, .milliseconds(5), "第 \(i + 1) 轮中位数")
        }
        let best = rounds.min { $0.p99 < $1.p99 }!
        XCTAssertLessThan(best.avg, .milliseconds(5))
        XCTAssertLessThan(best.p99, .milliseconds(5))
        all.sort()
        let pooledP99 = all[all.count * 99 / 100]
        print("S13 条码查找 合并 \(all.count) 次：p99 \(pooledP99)，最慢 \(all.last!)")
        XCTAssertLessThan(pooledP99, .milliseconds(20), "合并 p99 护栏")
    }

    /// 计时挡不住「丢了索引」：查找和前缀匹配都必须走条码主键（§14 S13-3 的建议）
    func testLookupAndPrefixMatchUseBarcodeIndex() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        func plan(_ sql: String, _ args: StatementArguments) throws -> [String] {
            try db.writer.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + sql, arguments: args).map { $0["detail"] as String } }
        }
        let l = try plan(LocalDB.lookupSQL, ["6901234500011"])
        XCTAssertTrue(l.contains { $0.hasPrefix("SEARCH b USING") && $0.contains("(barcode=?)") }, "\(l)")
        XCTAssertFalse(l.contains { $0.hasPrefix("SCAN") }, "\(l)")
        let input = "69025143"
        let p = try plan(LocalDB.prefixMatchSQL, [input, input + "\u{10FFFF}", input.count, input])
        XCTAssertTrue(p.contains { $0.hasPrefix("SEARCH b USING") && $0.contains("barcode>? AND barcode<?") }, "\(p)")
        XCTAssertFalse(p.contains { $0.hasPrefix("SCAN") }, "\(p)")
    }

    // MARK: - 验收 2：prefix.json 向量（纯函数和本地库两层）

    func testPrefixVectors() throws {
        let v = try XCTUnwrap(loadJSON("contracts/vectors/prefix.json") as? [String: Any])
        let catalog = try XCTUnwrap(v["catalog"] as? [[String: Any]])
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 12)

        // 向量里的商品 id 是 P1… 这样的名字，映射成 UUID
        var idMap: [String: UUID] = [:]
        var products: [UUID: Product] = [:]
        var records: [BarcodeRecord] = []
        for row in catalog {
            let pid = try XCTUnwrap(row["product_id"] as? String)
            let pq = try XCTUnwrap(int64(row["pack_qty"]))
            let u = idMap[pid] ?? uuid(0x500 + idMap.count)
            idMap[pid] = u
            if products[u] == nil {
                products[u] = try Product(id: u, name: try XCTUnwrap(row["name"] as? String), baseUnit: "个", priceFen: Fen(300))
            }
            records.append(try BarcodeRecord(barcode: try XCTUnwrap(row["barcode"] as? String), productId: u, packQty: pq,
                                             unitName: pq == 1 ? "个" : "箱"))
        }
        let name = Dictionary(uniqueKeysWithValues: idMap.map { ($1, $0) })
        let conversions = try records.map { try PackConversion(product: products[$0.productId]!, barcode: $0) }

        let db = try open()
        try db.beginSession(session(.cashier, device: 2))
        try db.applyBaseline(CatalogBaseline(products: Array(products.values), barcodes: records))

        func triples(_ cs: [BarcodeMatch.Candidate]) -> [String] {
            cs.map { "\(name[$0.conversion.product.id]!)/\($0.conversion.packQty)/\($0.representativeBarcode)" }
        }
        func expected(_ arr: Any?) throws -> [String] {
            try XCTUnwrap(arr as? [[String: Any]]).map { "\($0["product_id"]!)/\(int64($0["pack_qty"])!)/\($0["barcode"]!)" }
        }

        for c in cases {
            let id = c["id"] as! String
            let input = c["input"] as! String
            let exp = c["expected"] as! [String: Any]
            let pure = try BarcodeMatch.match(input: input, among: conversions.filter { $0.barcode.barcode.hasPrefix(input) })
            let local = try db.prefixMatch(input)
            for (layer, r) in [("纯函数", pure), ("本地库", local)] {
                XCTAssertEqual(r.listed, exp["listed"] as? Bool, "\(id) \(layer) listed")
                XCTAssertEqual(triples(r.candidates), try expected(exp["candidates"]), "\(id) \(layer) candidates")
                XCTAssertEqual(triples(r.shown), try expected(exp["shown"]), "\(id) \(layer) shown")
                XCTAssertEqual(Int64(r.moreCount), int64(exp["more_count"]), "\(id) \(layer) more_count")
                if let a = exp["auto_select"] as? [String: Any] {
                    let sel = try XCTUnwrap(r.autoSelect, "\(id) \(layer) 应自动选中")
                    XCTAssertEqual(name[sel.conversion.product.id], a["product_id"] as? String, id)
                    XCTAssertEqual(sel.conversion.packQty, int64(a["pack_qty"]), id)
                } else {
                    XCTAssertNil(r.autoSelect, "\(id) \(layer) 不应自动选")
                }
            }
        }
    }

    // MARK: - 验收 3：记账的原子性（写流水和写 outbox 之间注入崩溃）

    /// 崩溃 = 进程在两步之间死掉：在注入点把库文件（含 -wal/-shm）原样拷走，当作断电那一刻的磁盘，
    /// 再用拷贝「重启」。两者都不在。
    func testCrashBetweenEntriesAndOutboxLeavesNeither() throws {
        let crashDir = dir.appendingPathComponent("crash")
        let src = dbPath
        let hook: @Sendable (LocalDBFaultPoint) throws -> Void = { point in
            guard point == .afterEntriesBeforeOutbox else { return }
            try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: src + suffix) {
                try FileManager.default.copyItem(atPath: src + suffix, toPath: crashDir.appendingPathComponent("local.sqlite" + suffix).path)
            }
        }
        do {
            let db = try open(hook)
            try db.beginSession(session(.family, device: 1))
            try DemoSeed.install(into: db)
            try db.recordSale(try basket03(db))   // 正常进程里这一笔照常提交
            XCTAssertEqual(try db.count("entry"), 3)
            XCTAssertEqual(try db.count("outbox"), 1)
        }
        // 「重启」：打开崩溃那一刻的磁盘
        let restarted = try LocalDB(path: crashDir.appendingPathComponent("local.sqlite").path)
        XCTAssertEqual(try restarted.count("entry"), 0)
        XCTAssertEqual(try restarted.count("sale_batch"), 0)
        XCTAssertEqual(try restarted.count("outbox"), 0)
        XCTAssertEqual(try restarted.count("outbox_effect"), 0)
        XCTAssertEqual(try restarted.count("product"), 6, "崩溃前已提交的种子数据还在")
        // 提交之后再重启：两者都在
        let after = try open()
        XCTAssertEqual(try after.count("entry"), 3)
        XCTAssertEqual(try after.count("sale_batch"), 1)
        XCTAssertEqual(try after.pendingOps().count, 1)
    }

    /// 两步之间抛错（异常路径）：整笔回滚，两者都不在；库存的临时增减也没有
    func testFailureBetweenEntriesAndOutboxRollsBack() throws {
        struct Boom: Error {}
        let db = try open { if $0 == .afterEntriesBeforeOutbox { throw Boom() } }
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        XCTAssertThrowsError(try db.recordSale(try basket03(db)))
        let stockIn = try StockInPayload(entryId: uuid(0x77), conversion: XCTUnwrap(db.lookup(barcode: "6925303770020")),
                                         packCount: 5, unitCostFen: Fen(4800))
        XCTAssertThrowsError(try db.recordStockIn(stockIn, name: "可乐", unitName: "箱"))
        XCTAssertEqual(try db.count("entry"), 0)
        XCTAssertEqual(try db.count("sale_batch"), 0)
        XCTAssertEqual(try db.count("outbox"), 0)
        XCTAssertEqual(try db.displayStock(DemoSeed.id(0x202))?.qty, 48)
    }

    // MARK: - 验收 4：outbox 在 App 重启后仍在且顺序不变

    func testOutboxSurvivesRestartInOrder() throws {
        var ids: [UUID] = []
        var bytes: [Data] = []
        do {
            let db = try open()
            try db.beginSession(session(.family, device: 1))
            try DemoSeed.install(into: db)
            for i in 0..<10 {
                var b = Basket()
                try b.add(XCTUnwrap(db.lookup(barcode: i % 2 == 0 ? "6925303770013" : "6901028075862")))
                let opId = uuid(0x9000 + (9 - i))   // id 倒序，证明顺序靠 seq 而不是 id
                try db.recordSale(b, opId: opId)
                ids.append(opId)
            }
            bytes = try db.pendingOps().map(\.opJSON)
        }
        let db = try open()
        let pending = try db.pendingOps()
        XCTAssertEqual(pending.map(\.id), ids)
        XCTAssertEqual(pending.map(\.opJSON), bytes, "重发的字节不变")
        XCTAssertEqual(pending.map(\.seq), pending.map(\.seq).sorted())
        XCTAssertTrue(pending.allSatisfy { $0.type == .saleBatch && $0.deviceId == uuid(0xD01) && $0.tokenRef == "token.1" })
    }

    // MARK: - 验收 5：收银员形态建库后 product_private 为空，库文件里找不到进价数值

    static let markerCost: Int64 = 87_654_321   // 特征值：¥876,543.21

    func baselineWithMarker() throws -> CatalogBaseline {
        let p = try Product(id: uuid(0x601), name: "特征商品", baseUnit: "瓶", priceFen: Fen(1000))
        return CatalogBaseline(
            products: [p],
            barcodes: [try BarcodeRecord(barcode: "6900000000017", productId: p.id, unitName: "瓶")],
            privates: [try ProductPrivate(productId: p.id, stockQty: 1, stockValueFen: Fen(Self.markerCost),
                                          lastCostFen: Fen(Self.markerCost), costKnown: true)])
    }

    /// 库文件（含 -wal / -shm）里有没有特征值：十进制文本，以及 SQLite 存整数用的 4 / 6 / 8 字节大端
    func fileContainsMarker(at path: String? = nil) throws -> Bool {
        let base = path ?? dbPath
        var needles: [Data] = [Data(String(Self.markerCost).utf8)]
        for width in [4, 6, 8] {
            needles.append(Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: Self.markerCost >> (8 * $0)) }))
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            guard let data = FileManager.default.contents(atPath: base + suffix) else { continue }
            if needles.contains(where: { data.range(of: $0) != nil }) { return true }
        }
        return false
    }

    func testCashierDatabaseHasNoPrivateData() throws {
        do {
            let db = try open()
            try db.beginSession(session(.cashier, device: 2))
            // 服务器不会下发，但即使调用方误传了私有数据也整批拒掉
            XCTAssertInvalid(try db.applyBaseline(try self.baselineWithMarker()))
            var b = try baselineWithMarker()
            b.privates = []
            try db.applyBaseline(b)
            try DemoSeed.install(into: db)
            // 绕过仓库层直接写 SQL，触发器也拦
            XCTAssertThrowsError(try db.writer.write { try $0.execute(sql: """
                INSERT INTO product_private (product_id, stock_qty, stock_value_fen, last_cost_fen, cost_known, stock_ver, expiry_warn_days)
                VALUES (?, 1, ?, ?, 1, 0, 7)
                """, arguments: [uuid(0x601).uuidString, Self.markerCost, Self.markerCost]) })
            XCTAssertThrowsError(try db.writer.write { try $0.execute(sql: """
                INSERT INTO lot (id, product_id, qty_in, qty_left, handle_ver) VALUES ('x', 'y', 1, 1, 0)
                """) })
            // 收银员能卖、不能进货
            var basket = Basket()
            try basket.add(XCTUnwrap(db.lookup(barcode: "6900000000017")))
            try db.recordSale(basket)
            let si = try StockInPayload(entryId: uuid(0x78), productId: uuid(0x601), barcode: "6900000000017", packQty: 1,
                                        packCount: 1, unitCostFen: Fen(Self.markerCost))
            XCTAssertInvalid(try db.recordStockIn(si, name: "特征商品", unitName: "瓶"))

            XCTAssertEqual(try db.count("product_private"), 0)
            XCTAssertEqual(try db.count("lot"), 0)
            XCTAssertNil(try db.displayStock(uuid(0x601)))
            XCTAssertGreaterThan(try db.count("product"), 1)
        }
        XCTAssertFalse(try fileContainsMarker(), "收银员库文件里不该出现进价特征值")
    }

    /// 对照：同样的数据在家用形态下扫得到特征值（证明扫描本身有效）
    func testMarkerScanFindsValueOnFamilyDatabase() throws {
        do {
            let db = try open()
            try db.beginSession(session(.family, device: 1))
            try db.applyBaseline(try baselineWithMarker())
            XCTAssertEqual(try db.productPrivate(uuid(0x601))?.lastCostFen, Fen(Self.markerCost))
        }
        XCTAssertTrue(try fileContainsMarker())
    }

    /// 家用换成收银员（没有未传的进货类 op）：投影清空后，库文件里也找不到原来的进价
    func testSwitchingFamilyToCashierLeavesNoCostInFile() throws {
        do {
            let db = try open()
            try db.beginSession(session(.family, device: 1))
            try db.applyBaseline(try baselineWithMarker())
            try db.beginSession(session(.cashier, device: 2))
            try db.applyBaseline(CatalogBaseline(products: try baselineWithMarker().products))
            XCTAssertEqual(try db.count("product_private"), 0)
        }
        XCTAssertFalse(try fileContainsMarker())
    }

    // MARK: - 验收 6：清投影不清未确认的 outbox

    func testRoleSwitchClearsProjectionButKeepsUnconfirmedOps() throws {
        let db = try open()
        let family = try session(.family, device: 1)
        try db.beginSession(family)
        try DemoSeed.install(into: db)
        try db.setMeta(.catalogCursor, "1234")
        try db.setMeta(.serverEpoch, "epoch-1")
        // 3 条未确认的 op：卖出、进货、卖出；另有 1 条已确认
        try db.recordSale(try basket03(db), opId: uuid(0xE1))
        try db.recordStockIn(try StockInPayload(entryId: uuid(0xE9), conversion: XCTUnwrap(db.lookup(barcode: "6925303770020")),
                                                packCount: 5, unitCostFen: Fen(4800)),
                             name: "可口可乐 330ml", unitName: "箱", opId: uuid(0xE2))
        func cigBasket() throws -> Basket {
            var b = Basket()
            try b.add(XCTUnwrap(db.lookup(barcode: "6901028075879")))
            return b
        }
        try db.recordSale(try cigBasket(), opId: uuid(0xE3))
        try db.recordSale(try cigBasket(), opId: uuid(0xE4))
        try db.recordResults([try OpResult(id: uuid(0xE4), status: .applied)], storeId: Self.familyStore)
        XCTAssertEqual(try db.pendingOps().map(\.id), [uuid(0xE1), uuid(0xE2), uuid(0xE3)])

        // 换成另一家店的收银员（新设备 id、新令牌）
        let cashier = try session(.cashier, device: 2, store: Self.otherStore)
        try db.beginSession(cashier)

        for t in ["product", "product_private", "barcode", "entry", "sale_batch", "lot"] {
            XCTAssertEqual(try db.count(t), 0, "投影 \(t) 应清空")
        }
        XCTAssertNil(try db.meta(.catalogCursor))
        XCTAssertNil(try db.meta(.serverEpoch))
        XCTAssertEqual(try db.currentSession(), cashier)
        XCTAssertEqual(try db.pendingOps().count, 0, "新会话没有待传的")

        let rq = try db.recoveryQueue()
        XCTAssertEqual(rq.count, 1)
        XCTAssertEqual(rq[0].ops.map(\.id), [uuid(0xE1), uuid(0xE2), uuid(0xE3)])
        XCTAssertEqual(rq[0].storeId, Self.familyStore)
        XCTAssertEqual(rq[0].deviceId, family.deviceId)
        XCTAssertEqual(rq[0].tokenRef, family.tokenRef)
        XCTAssertTrue(rq[0].ops.allSatisfy { $0.storeId == Self.familyStore && $0.deviceId == family.deviceId && $0.tokenRef == "token.1" })
        XCTAssertEqual(try db.allOutbox().map(\.id), [uuid(0xE1), uuid(0xE2), uuid(0xE3)],
                       "换成收银员：旧家用会话已确认的那条立刻删，不留 14 天（§14 S13-1）")

        // 归属不可改绑：直接改 SQL 也被触发器拒绝
        for col in ["store_id", "device_id", "token_ref", "op_json", "seq"] {
            XCTAssertThrowsError(try db.writer.write { try $0.execute(sql: "UPDATE outbox SET \(col) = \(col == "seq" ? "seq + 100" : "'x'") WHERE id = ?",
                                                                     arguments: [uuid(0xE1).uuidString]) }, col)
        }

        // 重启后恢复队列仍在
        let reopened = try open()
        XCTAssertEqual(try reopened.recoveryQueue().first?.ops.map(\.id), [uuid(0xE1), uuid(0xE2), uuid(0xE3)])

        // 恢复队列传完之前不能忘掉旧会话；传完后才能删旧令牌
        XCTAssertTrue(try reopened.retiredSessionsWithoutPendingOps().isEmpty)
        XCTAssertInvalid(try reopened.forgetSession(deviceId: family.deviceId))
        try reopened.recordResults(try [uuid(0xE1), uuid(0xE2), uuid(0xE3)].map { try OpResult(id: $0, status: .applied) },
                                  storeId: Self.familyStore)
        XCTAssertEqual(try reopened.recoveryQueue().count, 0)
        XCTAssertEqual(try reopened.retiredSessionsWithoutPendingOps().map(\.tokenRef), ["token.1"])
        try reopened.forgetSession(deviceId: family.deviceId)
        XCTAssertTrue(try reopened.retiredSessionsWithoutPendingOps().isEmpty)
    }

    func testDemoResetDiscardsStoreOutbox() throws {
        let db = try open()
        try db.beginSession(session(.review, device: 1, store: DemoSeed.storeId))
        try DemoSeed.install(into: db)
        try db.recordSale(try basket03(db))
        try db.endSession()
        XCTAssertEqual(try db.recoveryQueue().count, 1)
        try db.discardOutbox(storeId: DemoSeed.storeId)
        XCTAssertEqual(try db.recoveryQueue().count, 0)
        XCTAssertEqual(try db.allOutbox().count, 0)
    }

    // MARK: - 验收 7：一个商品两个单件码，扫任一个或按名称找，得到同一个卖价

    func testTwoSingleCodesSamePriceByScanOrName() throws {
        let db = try open()
        try db.beginSession(session(.cashier, device: 2))
        try DemoSeed.install(into: db)
        let a = try XCTUnwrap(db.lookup(barcode: "6902514300011"))
        let b = try XCTUnwrap(db.lookup(barcode: "6902514300035"))
        XCTAssertEqual(a.product.id, b.product.id)
        XCTAssertEqual(try a.unitPrice(), Fen(450))
        XCTAssertEqual(try b.unitPrice(), Fen(450))

        let found = try db.searchByName("牛肉面")
        XCTAssertEqual(found.count, 1, "两个单件码按名称找只出一行")
        XCTAssertEqual(try found[0].unitPrice(), Fen(450))
        XCTAssertEqual(found[0].barcode.barcode, "6902514300011", "代表条码取最小的")

        // 扫两个不同的单件码进同一行
        var basket = Basket()
        try basket.add(a); try basket.add(b); try basket.add(found[0])
        XCTAssertEqual(basket.lines.count, 1)
        XCTAssertEqual(try basket.listTotal(), Fen(1350))

        // 单件和整箱按名称找是两行；整箱价按自己的价
        let coke = try db.searchByName("可乐")
        XCTAssertEqual(coke.map(\.packQty), [1, 24])
        XCTAssertEqual(try coke.map { try $0.unitPrice() }, [Fen(300), Fen(7200)])
        XCTAssertEqual(try db.searchByName("  "), [])
        XCTAssertEqual(try db.searchByName("不存在的东西"), [])
    }

    // MARK: - 临时库存：服务器基线与本机未确认增减分开存

    func testDisplayStockIsBaselinePlusPendingDeltas() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        let beer = DemoSeed.id(0x202), cig = DemoSeed.id(0x205)
        try db.recordSale(try basket03(db), opId: uuid(0xF1))                 // 青岛 −4
        var b = Basket()
        try b.add(XCTUnwrap(db.lookup(barcode: "6901035600023")))              // 青岛整箱 −24
        try db.recordSale(b, opId: uuid(0xF2))
        // 5 条 × ¥400、原有 6 包 → 56 包（S19 的例子）
        try db.recordStockIn(try StockInPayload(entryId: uuid(0xF9), conversion: XCTUnwrap(db.lookup(barcode: "6901028075879")),
                                                packCount: 5, unitCostFen: Fen(40000)),
                             name: "中华（硬）", unitName: "条", opId: uuid(0xF3))
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 48, pendingDelta: -28))
        XCTAssertEqual(try db.displayStock(cig)?.qty, 56)

        // 被拒的 op：增减自然消失；基线不被本地写入覆盖
        try db.recordResults([try OpResult(id: uuid(0xF2), status: .rejected, code: "forbidden")], storeId: Self.familyStore)
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 48, pendingDelta: -4))
        XCTAssertEqual(try db.productPrivate(beer)?.stockQty, 48)
        // 确认后，由拉取带来的新基线接手
        try db.recordResults([try OpResult(id: uuid(0xF1), status: .applied)], storeId: Self.familyStore)
        try db.applyBaseline(CatalogBaseline(privates: [try ProductPrivate(productId: beer, stockQty: 44, stockValueFen: Fen(44 * 420),
                                                                           lastCostFen: Fen(420), costKnown: true, stockVer: 2)]))
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 44, pendingDelta: 0))

        // 本地流水：分摊后的实收、负数量
        let lines = try db.entries().filter { $0.opId == uuid(0xF1) }.sorted { $0.amountFen > $1.amountFen }
        XCTAssertEqual(lines.map(\.amountFen), [Fen(2500), Fen(2400), Fen(450)])
        XCTAssertEqual(lines.map(\.qtyDelta), [-1, -4, -1])
    }

    // MARK: - 其他：只能联网的 op 不进队列；保留 14 天

    func testOnlineOnlyOpsAreNotQueuedAndRetention() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        let count = try CountPayload(entryId: uuid(0x31), productId: DemoSeed.id(0x201), countedQty: 10, baseQty: 12, baseVer: 1)
        XCTAssertInvalid(try db.enqueue(Op(payload: count)))

        let t0 = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        func one() throws -> Basket {
            var b = Basket()
            try b.add(XCTUnwrap(db.lookup(barcode: "6901234500011")))
            return b
        }
        try db.recordSale(try one(), opId: uuid(0x41), at: t0)
        try db.recordSale(try one(), opId: uuid(0x42), at: t0)
        try db.recordResults([try OpResult(id: uuid(0x41), status: .applied)], storeId: Self.familyStore, at: t0)
        let day13 = Calendar(identifier: .gregorian).date(byAdding: .day, value: 13, to: t0)!
        let day15 = Calendar(identifier: .gregorian).date(byAdding: .day, value: 15, to: t0)!
        XCTAssertEqual(try db.purgeConfirmed(now: day13), 0)
        XCTAssertEqual(try db.purgeConfirmed(now: day15), 1)
        XCTAssertEqual(try db.allOutbox().map(\.id), [uuid(0x42)], "未确认的永远不删")
    }

    // MARK: - §14 S13-1：收银员手机上已确认的旧会话 op 不留

    func stockInWithMarker(_ db: LocalDB, opId: UUID) throws {
        let si = try StockInPayload(entryId: uuid(0x79), productId: uuid(0x601), barcode: "6900000000017", packQty: 1,
                                    packCount: 1, unitCostFen: Fen(Self.markerCost))
        try db.recordStockIn(si, name: "特征商品", unitName: "瓶", opId: opId)
    }

    /// (a) 家用会话一条已确认、带特征值进价的进货 → 换成收银员 → 那条 op 删掉，库开着时文件里也扫不到
    func testConfirmedFamilyStockInDeletedWhenSwitchingToCashier() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try db.applyBaseline(try baselineWithMarker())
        try stockInWithMarker(db, opId: uuid(0xC1))
        try db.recordResults([try OpResult(id: uuid(0xC1), status: .applied)], storeId: Self.familyStore)
        XCTAssertTrue(try fileContainsMarker(), "对照：家用库里扫得到")
        try db.beginSession(session(.cashier, device: 2))
        XCTAssertEqual(try db.allOutbox().count, 0)
        XCTAssertFalse(try db.needsCompaction())
        XCTAssertFalse(try fileContainsMarker())
    }

    /// 同上，但走「家用退出或被踢 → 之后再扫收银员码」：beginSession 时没有旧的当前会话
    func testConfirmedFamilyStockInDeletedWhenCashierCodeScannedAfterLogout() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try db.applyBaseline(try baselineWithMarker())
        try stockInWithMarker(db, opId: uuid(0xC1))
        try db.recordResults([try OpResult(id: uuid(0xC1), status: .applied)], storeId: Self.familyStore)
        try db.endSession()
        XCTAssertEqual(try db.allOutbox().count, 1, "没有当前会话时照旧保留")
        try db.beginSession(session(.cashier, device: 3))
        XCTAssertEqual(try db.allOutbox().count, 0)
        XCTAssertFalse(try fileContainsMarker())
    }

    /// (b) 未确认的带特征值进货 → 换成收银员 → 仍在恢复队列（写明的例外）→ 拿到结果后立刻删、扫不到；
    /// 收银员自己的 op 照旧留 14 天
    func testUnconfirmedFamilyStockInDeletedOnceConfirmedUnderCashier() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try db.applyBaseline(try baselineWithMarker())
        try stockInWithMarker(db, opId: uuid(0xC2))
        try db.beginSession(session(.cashier, device: 2))
        XCTAssertEqual(try db.recoveryQueue().first?.ops.map(\.id), [uuid(0xC2)])
        XCTAssertTrue(try fileContainsMarker(), "写明的例外：未确认的旧 op 传完之前还在")

        let m = try baselineWithMarker()
        try db.applyBaseline(CatalogBaseline(products: m.products, barcodes: m.barcodes))
        var b = Basket()
        try b.add(XCTUnwrap(db.lookup(barcode: "6900000000017")))
        try db.recordSale(b, opId: uuid(0xC3))
        try db.recordResults([try OpResult(id: uuid(0xC3), status: .applied)], storeId: Self.familyStore)
        try db.recordResults([try OpResult(id: uuid(0xC2), status: .applied)], storeId: Self.familyStore)
        XCTAssertEqual(try db.recoveryQueue().count, 0)
        XCTAssertEqual(try db.allOutbox().map(\.id), [uuid(0xC3)], "收银员自己的已确认 op 照旧保留")
        XCTAssertFalse(try db.needsCompaction())
        XCTAssertFalse(try fileContainsMarker())
    }

    // MARK: - 换成收银员后压缩没做完：持久的「待压缩」标记

    /// 清投影的事务已提交、压缩还没跑时进程死掉：重开后先补做压缩，库开着时扫不到；恢复队列还在
    func testCrashAfterSwitchBeforeCompactIsRepairedOnReopen() throws {
        let crashDir = dir.appendingPathComponent("crash-compact")
        let copy = crashDir.appendingPathComponent("local.sqlite").path
        let src = dbPath
        do {
            let db = try open()
            try db.beginSession(session(.family, device: 1))
            try db.applyBaseline(try baselineWithMarker())
            var b = Basket()
            try b.add(XCTUnwrap(db.lookup(barcode: "6900000000017")))
            try db.recordSale(b, opId: uuid(0xC4))
        }
        do {
            let db = try open { point in
                guard point == .afterIdentitySwitchBeforeCompact else { return }
                try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: src + suffix) {
                    try FileManager.default.copyItem(atPath: src + suffix, toPath: copy + suffix)
                }
            }
            try db.beginSession(session(.cashier, device: 2))
        }
        XCTAssertTrue(try fileContainsMarker(at: copy), "崩溃那一刻的磁盘上还有旧进价（窗口确实存在）")
        let restarted = try LocalDB(path: copy)
        XCTAssertEqual(try restarted.currentSession()?.role, .cashier)
        XCTAssertEqual(try restarted.count("product_private"), 0)
        XCTAssertFalse(try restarted.needsCompaction())
        XCTAssertFalse(try fileContainsMarker(at: copy), "重开后补做压缩，库开着时也扫不到")
        XCTAssertEqual(try restarted.recoveryQueue().first?.ops.map(\.id), [uuid(0xC4)], "恢复队列保留")
        let m = try baselineWithMarker()
        try restarted.applyBaseline(CatalogBaseline(products: m.products, barcodes: m.barcodes))
        XCTAssertNotNil(try restarted.lookup(barcode: "6900000000017"))
        XCTAssertFalse(try fileContainsMarker(at: copy))
    }

    /// 换角色时界面开着一个读事务：截断被挡住不能当成功；标记保留，读事务结束后重试成功
    func testSwitchWithOpenReadTransactionKeepsCompactionPending() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try db.applyBaseline(try baselineWithMarker())
        let pool = try XCTUnwrap(db.writer as? DatabasePool)
        var snapshot: DatabaseSnapshot? = try pool.makeSnapshot()
        XCTAssertNotNil(snapshot)
        try db.beginSession(session(.cashier, device: 2))   // 换角色本身照常完成
        XCTAssertEqual(try db.currentSession()?.role, .cashier)
        XCTAssertTrue(try db.needsCompaction(), "截断没做成，标记必须还在")
        XCTAssertThrowsError(try db.compactIfNeeded()) { XCTAssertEqual($0 as? LocalDBError, .compactionBusy) }
        XCTAssertTrue(try db.needsCompaction())
        snapshot = nil
        try db.compactIfNeeded()
        XCTAssertFalse(try db.needsCompaction())
        XCTAssertFalse(try fileContainsMarker())
    }

    // MARK: - trimLedger：家用 35 天、收银员本机 2 天、绑着未确认 op 的不删

    func ts(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(f.date(from: s), s)
    }

    /// 拉取来的流水（没有 op）
    func insertPulledEntry(_ db: LocalDB, _ n: Int, device: UUID, at: String, batch: UUID) throws {
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT OR IGNORE INTO sale_batch (id, device_id, list_total_fen, paid_total_fen, occurred_at) VALUES (?, ?, 100, 100, ?)
                """, arguments: [batch.uuidString, device.uuidString, at])
            try d.execute(sql: """
                INSERT INTO entry (id, seq, batch_id, type, product_id, name_snapshot, qty_delta, list_amount_fen, amount_fen,
                  device_id, occurred_at) VALUES (?, ?, ?, 'sale', ?, '拉取的', -1, 100, 100, ?, ?)
                """, arguments: [uuid(n).uuidString, n, batch.uuidString, DemoSeed.id(0x201).uuidString, device.uuidString, at])
        }
    }

    func oneBottle(_ db: LocalDB) throws -> Basket {
        var b = Basket()
        try b.add(XCTUnwrap(db.lookup(barcode: "6901234500011")))
        return b
    }

    func testTrimLedgerFamilyKeeps35Days() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        let me = uuid(0xD01), other = uuid(0xD09)
        let b1 = uuid(0xB1), b2 = uuid(0xB2)
        try insertPulledEntry(db, 0x7001, device: me, at: "2026-10-17T00:00:00.000+08:00", batch: b1)     // 第 35 天：留
        try insertPulledEntry(db, 0x7002, device: me, at: "2026-10-16T23:59:59.999+08:00", batch: b1)     // 第 36 天：删
        try insertPulledEntry(db, 0x7003, device: other, at: "2026-10-01T09:00:00.000+08:00", batch: b2)  // 删，批次头跟着删
        try insertPulledEntry(db, 0x7004, device: other, at: "2026-11-19T09:00:00.000+08:00", batch: uuid(0xB4)) // 别的设备：家用全店都留
        try db.recordSale(try oneBottle(db), batchId: uuid(0xB3), opId: uuid(0xC5), at: try ts("2026-10-01T10:00:00.000+08:00"))
        let now = try ts("2026-11-20T12:00:00.000+08:00")

        XCTAssertEqual(try db.trimLedger(now: now), 2)
        let left = Set(try db.entries().map(\.id))
        XCTAssertTrue(left.isSuperset(of: [uuid(0x7001), uuid(0x7004)]))
        XCTAssertFalse(left.contains(uuid(0x7002)))
        XCTAssertFalse(left.contains(uuid(0x7003)))
        XCTAssertEqual(try db.entries().filter { $0.opId == uuid(0xC5) }.count, 1, "绑着未确认 op 的旧流水不删")
        let batches = try db.writer.read { try String.fetchAll($0, sql: "SELECT id FROM sale_batch ORDER BY id") }
        XCTAssertEqual(Set(batches), Set([b1, uuid(0xB3), uuid(0xB4)].map(\.uuidString)), "流水删光的批次头跟着删，还有流水的不删")

        try db.recordResults([try OpResult(id: uuid(0xC5), status: .applied)], storeId: Self.familyStore)
        XCTAssertEqual(try db.trimLedger(now: now), 1, "确认之后照常修剪")
        XCTAssertEqual(try db.count("sale_batch"), 2)
    }

    func testTrimLedgerCashierKeepsOwnTwoDays() throws {
        let db = try open()
        try db.beginSession(session(.cashier, device: 2))
        try DemoSeed.install(into: db)
        let me = uuid(0xD02), other = uuid(0xD09)
        try insertPulledEntry(db, 0x7101, device: me, at: "2026-11-19T00:00:00.000+08:00", batch: uuid(0xB5))     // 第 2 天：留
        try insertPulledEntry(db, 0x7102, device: me, at: "2026-11-18T23:59:59.999+08:00", batch: uuid(0xB6))     // 第 3 天：删
        try insertPulledEntry(db, 0x7103, device: other, at: "2026-11-20T09:00:00.000+08:00", batch: uuid(0xB7))  // 别的设备：删
        try db.recordSale(try oneBottle(db), batchId: uuid(0xB8), opId: uuid(0xC6), at: try ts("2026-11-15T10:00:00.000+08:00"))
        XCTAssertEqual(try db.trimLedger(now: try ts("2026-11-20T12:00:00.000+08:00")), 2)
        let left = try db.entries()
        XCTAssertEqual(Set(left.map(\.id)).subtracting([uuid(0x7101)]).count, 1)
        XCTAssertTrue(left.contains { $0.id == uuid(0x7101) })
        XCTAssertTrue(left.contains { $0.opId == uuid(0xC6) }, "绑着未确认 op 的不删")
        XCTAssertEqual(try db.count("sale_batch"), 2)
    }

    // MARK: - Codex 意见

    /// 同店换会话：旧会话（恢复队列）未确认的增减照算；别的店同一个商品 id 不算
    func testDisplayStockCountsSameStoreOldSessionsOnly() throws {
        let db = try open()
        let beer = DemoSeed.id(0x202)
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        try db.recordSale(try basket03(db), opId: uuid(0xC7))   // 青岛 −4
        try db.endSession()
        try db.beginSession(session(.family, device: 3))
        try DemoSeed.install(into: db)
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 48, pendingDelta: -4))
        try db.beginSession(session(.family, device: 4, store: Self.otherStore))
        try DemoSeed.install(into: db)
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 48, pendingDelta: 0), "别的店的不算")
    }

    /// op id 只在店内唯一（§14 S02-8）：两家店同一个 op id 共存，各自确认互不影响
    func testSameOpIdInTwoStores() throws {
        let db = try open()
        let x = uuid(0xAB), beer = DemoSeed.id(0x202)
        func oneBeer() throws -> Basket {
            var b = Basket()
            try b.add(XCTUnwrap(db.lookup(barcode: "6901035600016")))
            return b
        }
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        try db.recordSale(try oneBeer(), opId: x)
        try db.beginSession(session(.family, device: 2, store: Self.otherStore))
        try DemoSeed.install(into: db)
        try db.recordSale(try oneBeer(), opId: x)
        func status(_ store: UUID) throws -> OutboxItem.Status? {
            try db.allOutbox().first { $0.id == x && $0.storeId == store }?.status
        }
        XCTAssertEqual(try db.allOutbox().filter { $0.id == x }.count, 2)

        try db.recordResults([try OpResult(id: x, status: .rejected, code: "forbidden")], storeId: Self.otherStore)
        XCTAssertEqual(try status(Self.otherStore), .rejected)
        XCTAssertEqual(try status(Self.familyStore), .pending)
        XCTAssertEqual(try db.displayStock(beer), DisplayStock(baselineQty: 48, pendingDelta: 0))
        XCTAssertEqual(try db.recoveryQueue().first?.ops.map(\.id), [x])

        try db.recordResults([try OpResult(id: x, status: .applied)], storeId: Self.familyStore)
        XCTAssertEqual(try status(Self.familyStore), .applied)
        XCTAssertEqual(try status(Self.otherStore), .rejected)
    }

    /// 只有新商品登记第二步的、不带版本的期初能离线排队（§5.6 第 1、3 条）
    func testOpeningQueuesOnlyForNewProductWithoutVersion() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        func opening(_ pid: UUID, _ n: Int, baseVer: Int64? = nil) throws -> Op {
            Op(payload: try OpeningPayload(entryId: uuid(n), productId: pid, countedQty: 10, baseVer: baseVer, baseQty: baseVer.map { _ in 12 }))
        }
        let existing = DemoSeed.id(0x201)
        XCTAssertInvalid(try db.enqueue(try opening(existing, 0x51)), "已有商品不带版本")
        XCTAssertInvalid(try db.enqueue(try opening(existing, 0x52, baseVer: 1)), "已有商品带版本：走在线提交")
        let fresh = uuid(0x5A)
        XCTAssertInvalid(try db.enqueue(try opening(fresh, 0x53)), "本机没有登记这个商品")
        try db.enqueue(Op(payload: try ProductUpsertPayload.full(productId: fresh, barcode: "6900000000994", name: "新商品",
                                                                 priceFen: Fen(500), baseUnit: "个")))
        XCTAssertInvalid(try db.enqueue(try opening(fresh, 0x54, baseVer: 0)), "带了版本就不是登记第二步")
        try db.enqueue(try opening(fresh, 0x55), effects: [StockEffect(productId: fresh, qtyDelta: 10)])
        XCTAssertInvalid(try db.enqueue(try opening(fresh, 0x56)), "已有库存变动，再来一条期初要联网")
        XCTAssertEqual(try db.pendingOps().map(\.type), [.productUpsert, .opening])
    }

    /// 历史期初看 op 本身，不看增减：数量为 0 的期初（增减为 0 不保存）、省略 effects 的期初、省略 effects 的进货，
    /// 之后再来一条无版本期初都要联网（Codex 第二轮 P2）。被拒的不算
    func testOpeningHistoryJudgedByOpsNotEffects() throws {
        let db = try open()
        try db.beginSession(session(.family, device: 1))
        try DemoSeed.install(into: db)
        func register(_ pid: UUID, _ barcode: String) throws {
            try db.enqueue(Op(payload: try ProductUpsertPayload.full(productId: pid, barcode: barcode, name: "新商品",
                                                                     priceFen: Fen(500), baseUnit: "个")))
        }
        func opening(_ pid: UUID, _ n: Int, qty: Int64) throws -> Op {
            Op(id: uuid(0x5100 + n), payload: try OpeningPayload(entryId: uuid(0x5200 + n), productId: pid, countedQty: qty))
        }

        let zero = uuid(0x5B)
        try register(zero, "6900000000987")
        try db.enqueue(try opening(zero, 1, qty: 0), effects: [StockEffect(productId: zero, qtyDelta: 0)])
        XCTAssertInvalid(try db.enqueue(try opening(zero, 2, qty: 5)), "数量为 0 的期初也是一次期初")

        let omitted = uuid(0x5C)
        try register(omitted, "6900000000970")
        try db.enqueue(try opening(omitted, 3, qty: 7))   // 省略 effects
        XCTAssertInvalid(try db.enqueue(try opening(omitted, 4, qty: 7)), "省略 effects 的期初也算")

        let stocked = uuid(0x5D)
        try register(stocked, "6900000000963")
        try db.enqueue(Op(payload: try StockInPayload(entryId: uuid(0x5301), productId: stocked, barcode: "6900000000963",
                                                      packQty: 1, packCount: 3, unitCostFen: Fen(100))))
        XCTAssertInvalid(try db.enqueue(try opening(stocked, 5, qty: 3)), "进过货（省略 effects）就不是新商品")

        // 被拒的期初不算：重新数一次可以离线排队
        let rejected = uuid(0x5E)
        try register(rejected, "6900000000956")
        try db.enqueue(try opening(rejected, 6, qty: 0))
        try db.recordResults([try OpResult(id: uuid(0x5106), status: .rejected, code: "stale")], storeId: Self.familyStore)
        try db.enqueue(try opening(rejected, 7, qty: 2))

        XCTAssertEqual(try db.pendingOps().filter { $0.type == .opening }.map(\.id), [uuid(0x5101), uuid(0x5103), uuid(0x5107)])
    }

    // MARK: - 压缩标记的并发（Codex 第二轮 P1）

    final class Interleave: @unchecked Sendable {
        let lock = NSLock()
        var armed = false
        var errors: [Error] = []
        let bCommitted = DispatchSemaphore(value: 0)
        let aDone = DispatchSemaphore(value: 0)
        let bDone = DispatchSemaphore(value: 0)
        var db: LocalDB?
        func take() -> Bool { lock.withLock { defer { armed = false }; return armed } }
        func fail(_ e: Error) { lock.withLock { errors.append(e) } }
    }

    /// 线程 A 压缩做成、还没清标记时，线程 B 的 `recordResults` 删掉旧会话带进价的进货 op 并记标记，
    /// 且 B 在 A 清完之后才查标记：B 的压缩请求不能被 A 清掉，最后标记清掉时文件里也扫不到进价。
    /// 旧代码（截断与清标记分两段写访问）上 B 会提交在 A 清标记之前、查标记在之后，跳过压缩，文件里留着进价。
    func testCompactionMarkNotLostWhenResultsInterleave() throws {
        let box = Interleave()
        let db = try open { point in
            switch point {
            case .afterCompactBeforeClearingMark:
                guard box.take(), let db = box.db else { return }
                DispatchQueue.global().async {
                    do {
                        try db.recordResults([try OpResult(id: uuid(0xC2), status: .applied)], storeId: Self.familyStore)
                    } catch { box.fail(error) }
                    box.bDone.signal()
                }
                // 新代码里 B 被写队列挡住，这里等满 1 秒后照常清标记；旧代码里 B 立刻提交
                _ = box.bCommitted.wait(timeout: .now() + 1)
            case .afterResultsBeforeCompact:
                box.bCommitted.signal()
                // B 查标记一定排在 A 清完之后
                _ = box.aDone.wait(timeout: .now() + 10)
            default: return
            }
        }
        box.db = db
        try db.beginSession(session(.family, device: 1))
        try db.applyBaseline(try baselineWithMarker())
        try stockInWithMarker(db, opId: uuid(0xC2))
        try db.beginSession(session(.cashier, device: 2))
        XCTAssertFalse(try db.needsCompaction())
        XCTAssertTrue(try fileContainsMarker(), "对照：未确认的旧进货 op 还在")

        try db.setMeta(.compactPending, "1")   // 有一次待做的压缩（例如上次被读事务挡住）
        box.lock.withLock { box.armed = true }
        try db.compactIfNeeded()               // 线程 A
        box.aDone.signal()
        XCTAssertEqual(box.bDone.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(box.errors.isEmpty, "\(box.errors)")

        XCTAssertEqual(try db.allOutbox().count, 0, "旧会话的进货 op 拿到结果就删")
        XCTAssertFalse(try db.needsCompaction())
        XCTAssertFalse(try fileContainsMarker(), "B 的压缩请求没被 A 清掉")
    }
}
