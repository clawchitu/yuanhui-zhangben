import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S20 记的账与撤销：撤销是追加冲销行、不删；临时库存恢复；实收、摊后金额和契约向量逐分一致；
/// 重复撤销、已同步 / 未同步、跨日、收银员越权都有用例。
final class RecordsTests: XCTestCase {
    static let erguotou = "6901234500011", beer = "6901035600016", noodle = "6902514300011", colaPack = "6925303770020"
    /// 2026-11-19 19:32（上海），设计稿 07a 第一张卡的时间
    static let t1932 = Date(timeIntervalSince1970: 1_795_088_880 - 16 * 60)
    static let nextDay = t1932.addingTimeInterval(86_400)
    let me = uuid(0xD20), other = uuid(0xD21)

    func db(_ role: Role, device: UUID? = nil) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: device ?? me, storeId: DemoSeed.storeId, role: role, tokenRef: "t20",
                                             storeName: "元辉烟酒店", deviceLabel: role == .cashier ? "小王的手机" : "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    /// 设计稿 03 / 08：二锅头 ×1、青岛 ×4、康师傅 ×1，原价 53.50 实收 53.00
    func designSale(_ db: LocalDB, at t: Date = t1932) throws -> UUID {
        var b = Basket()
        for (code, n) in [(Self.erguotou, 1), (Self.beer, 4), (Self.noodle, 1)] {
            let conv = try XCTUnwrap(try db.lookup(barcode: code))
            for _ in 0..<n { try b.add(conv) }
        }
        try b.setPaid(Fen(5300))
        let batch = UUID()
        try db.recordSale(b, batchId: batch, at: t)
        return batch
    }

    func stock(_ db: LocalDB, _ code: String) throws -> Int64 {
        let p = try XCTUnwrap(try db.lookup(barcode: code)).product.id
        return try XCTUnwrap(try db.displayStock(p)).qty
    }

    func rows(_ db: LocalDB) throws -> [Row] {
        try db.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM entry ORDER BY rowid") }
    }

    // MARK: 08 的数和 allocation.json 逐分一致

    func testUndoSheetFiguresMatchAllocationVector() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/allocation.json") as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let v = try XCTUnwrap(cases.first { $0["id"] as? String == "alloc-01" }, "必过向量 53.50→53.00")
        XCTAssertEqual(v["paid_total_fen"] as? Int, 5300)
        XCTAssertEqual((v["expect"] as? [String: Any])?["list_fen"] as? [Int], [2500, 2400, 450])
        let expected = try XCTUnwrap((v["expect"] as? [String: Any])?["amount_fen"] as? [Int])

        let db = try db(.family)
        _ = try designSale(db)
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        XCTAssertEqual(card.lines.map { Int($0.amountFen) }, expected, "08 每行「退 ¥」= 摊后金额 24.76 / 23.78 / 4.46")
        XCTAssertEqual(card.discountFen, 50, "这笔抹了 ¥0.50")
        XCTAssertEqual(card.amountFen, 5300)
        XCTAssertEqual(card.lines.map(\.quantityText), ["×1", "×4", "×1"])
        XCTAssertEqual(card.deviceLabel, "柜台手机")
        XCTAssertEqual(card.time, "19:32")
    }

    // MARK: 整笔都撤销

    func testVoidWholeBatchAppendsReversalsAndRestoresStock() throws {
        let db = try db(.family)
        let before = try [Self.erguotou, Self.beer, Self.noodle].map { try stock(db, $0) }
        let batch = try designSale(db)
        XCTAssertEqual(try [Self.erguotou, Self.beer, Self.noodle].map { try stock(db, $0) }, [before[0] - 1, before[1] - 4, before[2] - 1])

        let undoAt = Self.t1932.addingTimeInterval(300)
        guard case .voided(_, let n) = try db.void(.batch(batch), at: undoAt) else { return XCTFail("应撤成功") }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(try [Self.erguotou, Self.beer, Self.noodle].map { try stock(db, $0) }, before, "临时库存恢复")

        let all = try rows(db)
        XCTAssertEqual(all.count, 6, "原行 3 + 冲销行 3，一行都没删")
        let originals = all.filter { ($0["reverses_entry_id"] as String?) == nil }
        let reversals = all.filter { ($0["reverses_entry_id"] as String?) != nil }
        XCTAssertTrue(originals.allSatisfy { ($0["voided_at"] as String?) == Op.formatTimestamp(undoAt) }, "原行打 voided_at")
        XCTAssertEqual(reversals.map { $0["amount_fen"] as Int64 }, [-2476, -2378, -446], "退的是摊后金额")
        XCTAssertEqual(reversals.map { $0["qty_delta"] as Int64 }, [1, 4, 1])
        XCTAssertEqual(reversals.map { $0["list_amount_fen"] as Int64 }, [-2500, -2400, -450])
        XCTAssertTrue(reversals.allSatisfy { ($0["batch_id"] as String?) == batch.uuidString && $0["type"] as String == "sale" })
        XCTAssertTrue(reversals.allSatisfy { ($0["occurred_at"] as String) == Op.formatTimestamp(undoAt) })
        // I4：未撤 + 已撤 = 实收；全部行（含冲销）的实收合计为 0
        XCTAssertEqual(originals.map { $0["amount_fen"] as Int64 }.reduce(0, +), 5300)
        XCTAssertEqual(all.map { $0["amount_fen"] as Int64 }.reduce(0, +), 0)

        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        XCTAssertTrue(card.allVoided, "原流水划线仍可见")
        XCTAssertEqual(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).count, 1, "冲销行不单独成卡")

        let ops = try db.pendingOps()
        XCTAssertEqual(ops.map(\.type), [.saleBatch, .void], "原卖出 op 不删，后面追加一条 void")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: ops[1].opJSON) as? [String: Any])["payload"] as? [String: Any]
        XCTAssertEqual((payload?["target"] as? [String: Any])?["batch_id"] as? String, batch.uuidString.lowercased())
        XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(ops[1].opJSON)), [], "void op 合 ops.schema.json")
    }

    // MARK: 只撤这样

    func testVoidOneLineRefundsItsAllocatedAmount() throws {
        let db = try db(.family)
        let beerBefore = try stock(db, Self.beer), erBefore = try stock(db, Self.erguotou)
        _ = try designSale(db)
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        let beerLine = card.lines[1]
        XCTAssertEqual(beerLine.amountFen, 2378)
        guard case .voided(_, 1) = try db.void(.entry(beerLine.id), at: Self.t1932.addingTimeInterval(60)) else { return XCTFail() }
        XCTAssertEqual(try stock(db, Self.beer), beerBefore, "青岛 4 罐加回")
        XCTAssertEqual(try stock(db, Self.erguotou), erBefore - 1, "别的行不动")
        let after = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        XCTAssertEqual(after.lines.map(\.voided), [false, true, false])
        XCTAssertEqual(after.openLines.map(\.amountFen).reduce(0, +) + 2378, 5300, "I4：未撤 + 已撤 = 实收")
        let rev = try rows(db).filter { ($0["reverses_entry_id"] as String?) == beerLine.id.uuidString }
        XCTAssertEqual(rev.map { $0["amount_fen"] as Int64 }, [-2378])
        let op = try XCTUnwrap(try db.pendingOps().last)
        let target = ((try JSONSerialization.jsonObject(with: op.opJSON) as? [String: Any])?["payload"] as? [String: Any])?["target"] as? [String: Any]
        XCTAssertEqual(target?["entry_id"] as? String, beerLine.id.uuidString.lowercased())
    }

    // MARK: 撤两次

    func testVoidTwiceSecondIsNoop() throws {
        let db = try db(.family)
        let batch = try designSale(db)
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        _ = try db.void(.entry(card.lines[0].id), at: Self.t1932)
        XCTAssertEqual(try db.void(.entry(card.lines[0].id), at: Self.t1932), .alreadyVoided, "同一行撤两次")
        let stockAfterOne = try stock(db, Self.erguotou)
        // 撤过一行后整笔撤：只撤剩下两行
        guard case .voided(_, 2) = try db.void(.batch(batch), at: Self.t1932) else { return XCTFail("剩下两行") }
        XCTAssertEqual(try db.void(.batch(batch), at: Self.t1932), .alreadyVoided, "整笔撤两次")
        XCTAssertEqual(try stock(db, Self.erguotou), stockAfterOne, "第二次不再加回库存")
        XCTAssertEqual(try rows(db).count, 6, "3 原行 + 3 冲销行，没有多的")
        XCTAssertEqual(try db.pendingOps().map(\.type), [.saleBatch, .void, .void], "第二次不写 op")
        XCTAssertFalse(try db.canVoid(try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)))
    }

    // MARK: 已同步的账（服务器基线里已经扣过）与未同步的账

    func testVoidSyncedAndUnsyncedEntries() throws {
        let db = try db(.family)
        // 未同步：本机记的、op 还在 outbox
        let pendingBatch = try designSale(db)
        // 已同步：卖出 op 确认了（基线 S22a 才会更新，这里模拟拉取：基线已扣、op 已确认）
        let ops = try db.pendingOps()
        try db.recordResults([try OpResult(id: ops[0].id, status: .applied)], storeId: DemoSeed.storeId)
        let beer = try XCTUnwrap(try db.lookup(barcode: Self.beer)).product.id
        let base = try XCTUnwrap(try db.productPrivate(beer))
        try db.applyBaseline(CatalogBaseline(privates: [try ProductPrivate(productId: beer, stockQty: base.stockQty - 4,
            stockValueFen: Fen(base.stockValueFen.raw - 4 * 420), lastCostFen: base.lastCostFen, costKnown: true, stockVer: 2)]))
        let synced = try stock(db, Self.beer)
        _ = try db.void(.batch(pendingBatch), at: Self.t1932)
        XCTAssertEqual(try stock(db, Self.beer), synced + 4, "已同步的卖出撤销：基线 + 未确认的 void 增减")

        // 从服务器拉下来的进货（别的手机记的、已同步）：撤销后临时库存减回去，冲销行照抄进价、取反货值
        let colaId = try XCTUnwrap(try db.lookup(barcode: Self.colaPack)).product.id
        let colaBefore = try stock(db, Self.colaPack)
        let entry = PulledEntry(seq: 7, opId: UUID(), productId: colaId, name: "可口可乐 330ml", unitName: "箱",
                                amounts: EntryAmounts(type: .stockIn, qtyDelta: 120, amountFen: 24000, listAmountFen: 24000, cogsFen: 0,
                                                      valueDeltaFen: 24000, unitCostFen: 200, packQty: 24, packCount: 5),
                                deviceId: other, occurredAt: Self.t1932.addingTimeInterval(-82 * 60))
        try db.applyPulledLedger(batches: [], entries: [entry])
        try db.setDeviceLabels([other: "爸爸的手机"])
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first { $0.type == .stockIn })
        XCTAssertEqual(card.deviceLabel, "爸爸的手机", "流水上显示手机名")
        XCTAssertEqual(card.lines[0].quantityText, "5 箱")
        XCTAssertEqual(card.amountFen, 24000)
        _ = try db.void(.entry(entry.id), at: Self.t1932)
        XCTAssertEqual(try stock(db, Self.colaPack), colaBefore - 120)
        let rev = try XCTUnwrap(try rows(db).first { ($0["reverses_entry_id"] as String?) == entry.id.uuidString })
        XCTAssertEqual(rev["unit_cost_fen"] as Int64?, 200, "单价照抄不取反")
        XCTAssertEqual(rev["value_delta_fen"] as Int64?, -24000)
        XCTAssertEqual(rev["pack_count"] as Int64?, -5)
        XCTAssertEqual(rev["pack_qty"] as Int64?, 24)
    }

    // MARK: 冲销行和 cost.json 的 void 步逐分一致

    func testReversalMatchesCostVectors() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/cost.json") as? [String: Any])
        var checked = 0
        for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
            let steps = c["steps"] as? [[String: Any]] ?? []
            for step in steps {
                guard let action = step["action"] as? [String: Any], action["type"] as? String == "void",
                      let target = int64(action["target_step"]),
                      let expect = (step["expect"] as? [String: Any])?["entries"] as? [[String: Any]],
                      let rev = expect.first(where: { int64($0["reverses_step"]) != nil })
                else { continue }
                let id = c["id"] as? String ?? "?"
                let targetEntries = ((steps[Int(target)]["expect"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
                let type = try XCTUnwrap(EntryType(rawValue: rev["type"] as? String ?? ""), id)
                let orig = try XCTUnwrap(targetEntries.first { $0["type"] as? String == type.rawValue }, id)
                func amounts(_ e: [String: Any]) throws -> EntryAmounts {
                    EntryAmounts(type: type, qtyDelta: try XCTUnwrap(int64(e["qty_delta"])), amountFen: try XCTUnwrap(int64(e["amount_fen"])),
                                 listAmountFen: try XCTUnwrap(int64(e["list_amount_fen"])), cogsFen: int64(e["cogs_fen"]),
                                 valueDeltaFen: int64(e["value_delta_fen"]), costMissing: e["cost_missing"] as? Bool ?? false,
                                 unitCostFen: int64(e["unit_cost_fen"]))
                }
                XCTAssertEqual(try amounts(orig).reversal(), try amounts(rev), "\(id) 冲销行逐分")
                // 临时库存：服务器这一步全部流水（含 cost_fix 冲销、cost_adjust）的数量合计 = 手机记的增减
                let serverQty = expect.compactMap { int64($0["qty_delta"]) }.reduce(0, +)
                XCTAssertEqual(try amounts(orig).reversal().qtyDelta, serverQty, "\(id) 库存增减")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
        XCTAssertInvalid(try EntryAmounts(type: .costAdjust, qtyDelta: 0, amountFen: 0, listAmountFen: 0).reversal())
    }

    // MARK: 跨日

    func testFamilyVoidsYesterdayCountsOnTheDayOfUndo() throws {
        let db = try db(.family)
        let batch = try designSale(db)
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first)
        XCTAssertTrue(try db.canVoid(card, now: Self.nextDay), "家用：任意一天都能撤")
        _ = try db.void(.batch(batch), at: Self.nextDay)
        let ts = Op.formatTimestamp(Self.nextDay)
        let reversals = try rows(db).filter { ($0["reverses_entry_id"] as String?) != nil }
        XCTAssertTrue(reversals.allSatisfy { ($0["occurred_at"] as String) == ts }, "撤销算在撤销那天")
        XCTAssertEqual(try db.recordCards(on: LocalDB.shanghaiDay(Self.nextDay)).count, 0, "撤销本身不成卡")
        XCTAssertTrue(try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932)).first).allVoided, "昨天那张划线")
        // 07c：三天后看，记卖出那天 1 笔 ¥53.00，撤销那天 0 笔、−¥53.00（金额非零照样列）
        let days = try db.ledgerDays(now: Self.t1932.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(days.map(\.count), [0, 1])
        XCTAssertEqual(days.map(\.saleFen), [-5300, 5300])
    }

    // MARK: 收银员

    func testCashierCanOnlyVoidOwnSalesOfToday() throws {
        let db = try db(.cashier)
        let today = try designSale(db)
        let yesterday = try designSale(db, at: Self.t1932.addingTimeInterval(-86_400))
        // 别的手机记的卖出（不该出现在收银员手机上；万一在，也撤不了）
        let foreignBatch = UUID(), foreignEntry = UUID()
        let water = try XCTUnwrap(try db.lookup(barcode: "6921168509256")).product.id
        try db.applyPulledLedger(batches: [PulledBatch(id: foreignBatch, deviceId: other, listTotalFen: 200, paidTotalFen: 200, occurredAt: Self.t1932)],
                                 entries: [PulledEntry(id: foreignEntry, seq: 3, opId: UUID(), batchId: foreignBatch, productId: water, name: "农夫山泉 550ml",
                                                       amounts: EntryAmounts(type: .sale, qtyDelta: -1, amountFen: 200, listAmountFen: 200, packQty: 1, packCount: 1),
                                                       deviceId: other, occurredAt: Self.t1932)])

        let cards = try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932))
        XCTAssertEqual(cards.count, 1, "07b 只列本机的卖出")
        XCTAssertEqual(cards[0].deviceLabel, "小王的手机")
        XCTAssertTrue(try db.canVoid(cards[0], now: Self.t1932))
        XCTAssertFalse(try db.canVoid(cards[0], now: Self.nextDay), "过了零点，昨天的没有撤销按钮")
        let old = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Self.t1932.addingTimeInterval(-86_400))).first)
        XCTAssertFalse(try db.canVoid(old, now: Self.t1932))

        XCTAssertInvalid(try db.void(.batch(yesterday), at: Self.t1932), "昨天的卖出")
        XCTAssertInvalid(try db.void(.batch(foreignBatch), at: Self.t1932), "别的手机的卖出")
        XCTAssertInvalid(try db.void(.entry(foreignEntry), at: Self.t1932))
        XCTAssertEqual(try db.pendingOps().map(\.type), [.saleBatch, .saleBatch], "越权的撤销一条 op 都不写")
        XCTAssertTrue(try rows(db).allSatisfy { ($0["voided_at"] as String?) == nil })

        guard case .voided = try db.void(.batch(today), at: Self.t1932) else { return XCTFail("本机今天的能撤") }
        XCTAssertNil(try db.displayStock(uuid(1)), "收银员没有库存")
        let rev = try rows(db).filter { ($0["reverses_entry_id"] as String?) != nil }
        XCTAssertEqual(rev.count, 3)
        XCTAssertTrue(rev.allSatisfy { ($0["cogs_fen"] as Int64?) == nil && ($0["value_delta_fen"] as Int64?) == nil }, "收银员手机不出现成本")
        XCTAssertEqual(try db.ledgerDays(now: Self.nextDay.addingTimeInterval(2 * 86_400)), [], "收银员没有「更早」")
    }

    // MARK: 卡片按 op 归并（§14 S07-1）、07c 只列有账的日子、35 天

    func testCardsGroupByOpAndDaysList() throws {
        let db = try db(.family)
        let p = uuid(0x777), op = UUID(), sale = UUID()
        let day = Self.t1932.addingTimeInterval(-3 * 86_400)
        func e(_ type: EntryType, qty: Int64, amount: Int64 = 0, flags: String? = nil, reverses: UUID? = nil, id: UUID = UUID(), op: UUID) -> PulledEntry {
            PulledEntry(id: id, seq: 1, opId: op, reversesEntryId: reverses, productId: p, name: "桃李 醇熟切片面包",
                        amounts: EntryAmounts(type: type, qtyDelta: qty, amountFen: amount, listAmountFen: amount, cogsFen: 0, valueDeltaFen: -320 * -qty),
                        deviceId: other, occurredAt: day, flags: flags)
        }
        try db.applyPulledLedger(batches: [], entries: [
            e(.sale, qty: -1, amount: 650, id: sale, op: op),
            e(.costFix, qty: 0, amount: 650, op: op),                                  // 当场写的补记，同一个 op
            e(.count, qty: 1, flags: #"{"late_before_count":true}"#, op: op),        // 迟到补偿，同一个 op
            e(.costAdjust, qty: 0, op: UUID()),                                        // 调整不成卡、不算笔
            e(.expireLoss, qty: -2, op: UUID()),
        ])
        let cards = try db.recordCards(on: LocalDB.shanghaiDay(day))
        XCTAssertEqual(cards.map(\.type), [.expireLoss, .sale], "卡片数 = 笔数")
        XCTAssertEqual(cards[1].lines.count, 1, "补记和补偿行不单独成行")
        XCTAssertEqual(cards[0].amountFen, 640, "过期扔掉：算亏（按进价）")
        XCTAssertEqual(cards[0].deviceLabel, "别的手机", "没有名字的手机不显示人名")
        let days = try db.ledgerDays(now: Self.t1932)
        XCTAssertEqual(days.map(\.day), [LocalDB.shanghaiDay(day)])
        XCTAssertEqual(days.first?.count, 2)
        XCTAssertEqual(days.first?.saleFen, 650)
        XCTAssertEqual(try db.ledgerDays(now: day.addingTimeInterval(36 * 86_400)), [], "超出本地 35 天不列")
        XCTAssertEqual(try db.ledgerDays(now: day.addingTimeInterval(34 * 86_400)).count, 1)
        XCTAssertEqual(try db.ledgerDays(now: day.addingTimeInterval(86_400)), [], "昨天和今天不在「更早」里")
        // 不能撤冲销行和自动生成的行
        let adj = try rows(db).first { $0["type"] as String == "cost_adjust" }!
        XCTAssertInvalid(try db.void(.entry(try XCTUnwrap(UUID(uuidString: adj["id"]))), at: Self.t1932))
        _ = try db.void(.entry(sale), at: Self.t1932)
        let rev = try rows(db).first { ($0["reverses_entry_id"] as String?) == sale.uuidString }!
        XCTAssertInvalid(try db.void(.entry(try XCTUnwrap(UUID(uuidString: rev["id"]))), at: Self.t1932))
    }

    // MARK: 首页「刚记的」来自真数据

    func testLastRecordComesFromLedger() throws {
        let db = try db(.family)
        XCTAssertNil(try db.lastRecord(), "没有流水时不显示")
        let batch = try designSale(db)
        let last = try XCTUnwrap(try db.lastRecord())
        XCTAssertEqual(last.type, .sale)
        XCTAssertEqual(last.lines.count, 3)
        XCTAssertEqual(last.amountFen, 5300)
        _ = try db.void(.batch(batch), at: Self.t1932)
        XCTAssertNil(try db.lastRecord(), "全撤了的不当「刚记的」")
    }

    // MARK: 原子性：冲销行和 void op 要么都在要么都不在

    func testVoidIsAtomic() throws {
        struct Boom: Error {}
        let db = try LocalDB(writer: try DatabaseQueue(), faultHook: { if $0 == .afterEntriesBeforeOutbox { throw Boom() } })
        try db.beginSession(try LocalSession(deviceId: me, storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        let colaId = try XCTUnwrap(try db.lookup(barcode: Self.colaPack)).product.id
        let entry = PulledEntry(seq: 1, opId: UUID(), productId: colaId, name: "可乐",
                                amounts: EntryAmounts(type: .stockIn, qtyDelta: 24, amountFen: 4800, listAmountFen: 4800),
                                deviceId: me, occurredAt: Self.t1932)
        try db.applyPulledLedger(batches: [], entries: [entry])
        XCTAssertThrowsError(try db.void(.entry(entry.id), at: Self.t1932))
        XCTAssertEqual(try rows(db).count, 1, "冲销行回滚")
        XCTAssertNil(try rows(db)[0]["voided_at"] as String?)
        XCTAssertEqual(try db.allOutbox().count, 0)
    }
}
