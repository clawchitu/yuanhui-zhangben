import Foundation
import XCTest
@testable import ShopCore

/// S27 保质期：提醒规则和 expiry.json 的 remind 组一致；19 的三段（已过期 / 快过期 / 过几天再提醒的）；
/// 处理（20 / 20b）写进 outbox 的 op 和契约一致、处理完马上从清单和黄条消失；另一台手机已经处理过（stale）后批次回到清单；
/// 面板的突出顺序；「算亏」和 cost.json 的 expire_loss 逐分一致；收银员没有批次也记不了。
final class ExpiryTests: XCTestCase {
    static let today = try! CalendarDate("2026-11-19")
    // DemoSeed：青岛啤酒、康师傅、可口可乐各有一批 11/25 到期（提前 7 天提醒）
    static let beer = DemoSeed.id(0x202), noodle = DemoSeed.id(0x203), cola = DemoSeed.id(0x204), baijiu = DemoSeed.id(0x201)
    static let beerLot = DemoSeed.id(0x302)

    func db(_ role: Role = .family, extraLots: [LocalLot] = []) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: uuid(0xD27), storeId: DemoSeed.storeId, role: role, tokenRef: "t27",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        if !extraLots.isEmpty { try db.applyBaseline(CatalogBaseline(lots: extraLots)) }
        return db
    }

    // MARK: 规则

    func testRemindVectors() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/expiry.json") as? [String: Any])
        let cases = try XCTUnwrap(root["remind"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let id = c["id"] as? String ?? "?"
            let lot = try XCTUnwrap(c["lot"] as? [String: Any], id)
            let got = ExpiryRule.shouldRemind(
                today: try CalendarDate(try XCTUnwrap(c["today"] as? String)),
                expiry: try (lot["expiry_date"] as? String).map(CalendarDate.init),
                warnDays: try XCTUnwrap(int64(lot["expiry_warn_days"]), id), qtyLeft: try XCTUnwrap(int64(lot["qty_left"]), id),
                closed: try XCTUnwrap(lot["closed"] as? Bool, id), snoozedUntil: try (lot["snoozed_until"] as? String).map(CalendarDate.init))
            XCTAssertEqual(got, c["expected"] as? Bool, id)
        }
    }

    func testDayArithmetic() throws {
        XCTAssertEqual(try CalendarDate("2028-02-28").adding(days: 1).description, "2028-02-29")
        XCTAssertEqual(try CalendarDate("2027-02-28").adding(days: 1).description, "2027-03-01")
        XCTAssertEqual(try CalendarDate("2026-12-30").adding(days: 3).description, "2027-01-02")
        XCTAssertEqual(try CalendarDate("2026-01-01").adding(days: -1).description, "2025-12-31")
        XCTAssertEqual(try CalendarDate("2026-11-19").days(until: try CalendarDate("2026-11-17")), -2)
        XCTAssertInvalid(try CalendarDate("9999-12-31").adding(days: 1))
        // 往返：每天都能还原（跨几个闰年）
        var d = try CalendarDate("1999-12-25")
        for _ in 0..<3000 {
            let next = try d.adding(days: 1)
            XCTAssertEqual(try CalendarDate(dayNumber: next.dayNumber), next)
            XCTAssertLessThan(d, next)
            d = next
        }
    }

    // MARK: 19 的清单

    func testBoardSectionsAndKinds() throws {
        let db = try db(extraLots: [
            // 白酒：过了 2 天（11/17）
            try LocalLot(id: uuid(0xA1), productId: Self.baijiu, expiryDate: try CalendarDate("2026-11-17"), qtyIn: 2, qtyLeft: 2),
            // 青岛再来一批 11/21：同一样商品两批 → 两行，但「样」只算一次
            try LocalLot(id: uuid(0xA2), productId: Self.beer, expiryDate: try CalendarDate("2026-11-21"), qtyIn: 4, qtyLeft: 4),
            // 还早（12/30）、没填到期日、卖完了：都不列
            try LocalLot(id: uuid(0xA3), productId: Self.beer, expiryDate: try CalendarDate("2026-12-30"), qtyIn: 4, qtyLeft: 4),
            try LocalLot(id: uuid(0xA4), productId: Self.beer, expiryDate: nil, qtyIn: 4, qtyLeft: 4),
            try LocalLot(id: uuid(0xA5), productId: Self.beer, expiryDate: try CalendarDate("2026-11-18"), qtyIn: 4, qtyLeft: 0),
            // 在再提醒期内（11/22 恢复）
            try LocalLot(id: uuid(0xA6), productId: Self.noodle, expiryDate: try CalendarDate("2026-11-20"), qtyIn: 3, qtyLeft: 3,
                         snoozedUntil: try CalendarDate("2026-11-22"), handleVer: 1),
            // 再提醒到今天：恢复提醒
            try LocalLot(id: uuid(0xA7), productId: Self.noodle, expiryDate: try CalendarDate("2026-11-23"), qtyIn: 3, qtyLeft: 1,
                         snoozedUntil: Self.today, handleVer: 1),
        ])
        let b = try db.expiryBoard(today: Self.today)
        XCTAssertEqual(b.expired.map(\.lotId), [uuid(0xA1)])
        XCTAssertEqual(b.expired.first?.daysLeft, -2)
        XCTAssertTrue(b.expired.first?.expired ?? false)
        XCTAssertEqual(b.soon.map(\.lotId), [uuid(0xA2), uuid(0xA7), DemoSeed.id(0x304), DemoSeed.id(0x303), DemoSeed.id(0x302)],
                       "按到期日排，同日按名称")
        XCTAssertEqual(b.soon.first?.daysLeft, 2)
        XCTAssertEqual(b.snoozed.map(\.lotId), [uuid(0xA6)])
        XCTAssertEqual(b.snoozed.first?.snoozedUntil?.description, "2026-11-22")
        XCTAssertEqual(ExpiryBoard.kinds(b.soon), 3)
        XCTAssertEqual(b.remindKinds, 4, "白酒、青岛、康师傅、可乐：按商品合并")
        // 今天到期的算快过期，不算已过期
        let d2 = try self.db()
        let onDay = try d2.expiryBoard(today: try CalendarDate("2026-11-25"))
        XCTAssertEqual(onDay.soon.count, 3)
        XCTAssertTrue(onDay.expired.isEmpty)
        XCTAssertEqual(try d2.expiryBoard(today: try CalendarDate("2026-11-26")).expired.count, 3)
        XCTAssertEqual(try d2.expiryBoard(today: try CalendarDate("2026-11-17")).remindKinds, 0, "提前 7 天：11/18 才开始提醒")
    }

    func testArchivedProductNotListed() throws {
        let db = try db()
        let cola = try XCTUnwrap(try db.product(Self.cola))
        try db.applyBaseline(CatalogBaseline(products: [try Product(id: cola.id, name: cola.name, baseUnit: cola.baseUnit, priceFen: cola.priceFen,
                                                                    trackExpiry: true, archived: true)]))
        XCTAssertEqual(try db.expiryBoard(today: Self.today).remindKinds, 2)
    }

    // MARK: 处理（20 / 20b）

    func testDiscardQueuesOpAndLeavesBoard() throws {
        let db = try db()
        let item = try XCTUnwrap(try db.expiryBoard(today: Self.today).soon.first { $0.lotId == Self.beerLot })
        XCTAssertEqual(item.qtyLeft, 48)
        let opId = try db.handleExpiry(item, choice: .discard, actualQty: 5, opId: uuid(0xE1), entryId: uuid(0xE2))
        let o = try XCTUnwrap(try db.pendingOps().last)
        XCTAssertEqual(o.id, opId)
        XCTAssertEqual(o.type, .expiryDispose)
        let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: o.opJSON) as? [String: Any])?["payload"] as? [String: Any])
        XCTAssertEqual(payload["lot_id"] as? String, Self.beerLot.uuidString.lowercased())
        XCTAssertEqual(payload["action"] as? String, "discard")
        XCTAssertEqual(int64(payload["actual_qty"]), 5)
        XCTAssertEqual(int64(payload["handle_ver"]), 0)
        XCTAssertEqual(payload["entry_id"] as? String, uuid(0xE2).uuidString.lowercased())
        XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(o.opJSON)), [])
        XCTAssertEqual(try db.displayStock(Self.beer)?.qty, 43, "扔掉扣库存")
        let after = try db.expiryBoard(today: Self.today)
        XCTAssertFalse(after.soon.contains { $0.lotId == Self.beerLot })
        XCTAssertEqual(after.remindKinds, 2, "黄条少一样")
        XCTAssertEqual(try db.opStatus(opId)?.status, .pending)
    }

    func testSoldOutAndReturn() throws {
        let db = try db()
        let b = try db.expiryBoard(today: Self.today)
        let beer = try XCTUnwrap(b.soon.first { $0.productId == Self.beer })
        let noodle = try XCTUnwrap(b.soon.first { $0.productId == Self.noodle })
        try db.handleExpiry(beer, choice: .soldOut, actualQty: 0)
        try db.handleExpiry(noodle, choice: .return, actualQty: 4)
        XCTAssertEqual(try db.displayStock(Self.beer)?.qty, 48, "卖完了不动库存")
        XCTAssertEqual(try db.displayStock(Self.noodle)?.qty, 16)
        let actions = try db.pendingOps().compactMap { o -> String? in
            XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(o.opJSON)), [])
            return ((try JSONSerialization.jsonObject(with: o.opJSON) as? [String: Any])?["payload"] as? [String: Any])?["action"] as? String
        }
        XCTAssertEqual(actions, ["sold_out", "return"])
        XCTAssertEqual(try db.expiryBoard(today: Self.today).remindKinds, 1)
    }

    func testSnoozeMovesToSnoozedSection() throws {
        let db = try db()
        let item = try XCTUnwrap(try db.expiryBoard(today: Self.today).soon.first { $0.productId == Self.cola })
        try db.handleExpiry(item, choice: .snooze, actualQty: 7, at: try XCTUnwrap(LocalDB.parseTimestamp("2026-11-19T10:00:00.000+08:00")))
        let o = try XCTUnwrap(try db.pendingOps().last)
        XCTAssertEqual(o.type, .lotSnooze)
        XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(o.opJSON)), [])
        let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: o.opJSON) as? [String: Any])?["payload"] as? [String: Any])
        XCTAssertEqual(int64(payload["days"]), 3)
        XCTAssertEqual(int64(payload["actual_qty"]), 7)
        XCTAssertEqual(try db.displayStock(Self.cola)?.qty, 30, "再提醒不动库存")
        let b = try db.expiryBoard(today: Self.today)
        XCTAssertEqual(b.snoozed.map(\.productId), [Self.cola])
        XCTAssertEqual(b.snoozed.first?.qtyLeft, 7, "按填的实际数")
        XCTAssertEqual(b.snoozed.first?.snoozedUntil?.description, "2026-11-22")
        XCTAssertEqual(b.remindKinds, 2)
        // 到 11/22 当天恢复提醒
        XCTAssertEqual(try db.expiryBoard(today: try CalendarDate("2026-11-22")).remindKinds, 3)
    }

    /// 再提醒还没传上去、过了几天这批又回到清单时再处理：带的版本要算上没传的那条（服务器先应用再提醒，handle_ver + 1）
    func testHandleAfterPendingSnoozeCarriesNextVersion() throws {
        let db = try db()
        let item = try XCTUnwrap(try db.expiryBoard(today: Self.today).soon.first { $0.lotId == Self.beerLot })
        XCTAssertEqual(item.handleVer, 0)
        try db.handleExpiry(item, choice: .snooze, actualQty: 10, at: try XCTUnwrap(LocalDB.parseTimestamp("2026-11-19T10:00:00.000+08:00")))
        let later = try XCTUnwrap(try db.expiryBoard(today: try CalendarDate("2026-11-22")).soon.first { $0.lotId == Self.beerLot })
        XCTAssertEqual(later.handleVer, 1)
        XCTAssertEqual(later.qtyLeft, 10)
        try db.handleExpiry(later, choice: .discard, actualQty: 10)
        let vers = try db.pendingOps().map { o -> Int64? in
            int64(((try JSONSerialization.jsonObject(with: o.opJSON) as? [String: Any])?["payload"] as? [String: Any])?["handle_ver"])
        }
        XCTAssertEqual(vers, [0, 1])
    }

    /// 另一台手机已经处理过同一批：服务器拒 stale → 本机的处理作废，批次回到清单（拉下来的是服务器的最新状态）
    func testStaleRejectionBringsLotBack() throws {
        let db = try db()
        let item = try XCTUnwrap(try db.expiryBoard(today: Self.today).soon.first { $0.lotId == Self.beerLot })
        let opId = try db.handleExpiry(item, choice: .discard, actualQty: 5)
        XCTAssertEqual(try db.expiryBoard(today: Self.today).remindKinds, 2)
        try db.recordResults([try OpResult(id: opId, status: .rejected, code: "stale")], storeId: DemoSeed.storeId)
        let st = try XCTUnwrap(try db.opStatus(opId))
        XCTAssertEqual(st.status, .rejected)
        XCTAssertEqual(st.code, "stale")
        XCTAssertEqual(try db.displayStock(Self.beer)?.qty, 48, "被拒的不扣库存")
        XCTAssertEqual(try db.expiryBoard(today: Self.today).remindKinds, 3)
        XCTAssertNil(try db.opStatus(uuid(0xFFFF)))
    }

    func testZeroQtyCannotDiscardOrReturn() throws {
        let db = try db()
        let item = try XCTUnwrap(try db.expiryBoard(today: Self.today).soon.first)
        XCTAssertInvalid(try db.handleExpiry(item, choice: .discard, actualQty: 0))
        XCTAssertInvalid(try db.handleExpiry(item, choice: .return, actualQty: 0))
        XCTAssertTrue(try db.pendingOps().isEmpty)
        XCTAssertInvalid(try db.handleExpiry(item, choice: .snooze, actualQty: Limits.maxBaseQty + 1))
    }

    func testChoiceOrder() {
        XCTAssertEqual(ExpiryChoice.order(expired: true, actualQty: 2), [.discard, .soldOut, .return, .snooze], "20：已过期突出扔掉")
        XCTAssertEqual(ExpiryChoice.order(expired: false, actualQty: 3), [.snooze, .soldOut, .return, .discard], "20b：没过期突出再提醒")
        XCTAssertEqual(ExpiryChoice.order(expired: true, actualQty: 0).first, .soldOut)
        XCTAssertEqual(ExpiryChoice.order(expired: false, actualQty: 0).first, .soldOut)
        XCTAssertFalse(ExpiryChoice.discard.enabled(actualQty: 0))
        XCTAssertFalse(ExpiryChoice.return.enabled(actualQty: 0))
        XCTAssertTrue(ExpiryChoice.soldOut.enabled(actualQty: 0))
        XCTAssertTrue(ExpiryChoice.snooze.enabled(actualQty: 0))
        XCTAssertTrue(ExpiryChoice.discard.enabled(actualQty: 1))
    }

    // MARK: 算亏

    /// cost.json 里每个 expire_loss 步：按那一步之前的状态预计的亏损 = 服务器记的 cogs_fen
    func testLossEstimateMatchesCostVectors() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/cost.json") as? [String: Any])
        var checked = 0
        for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
            var state = c["initial"] as? [String: Any]
            for step in c["steps"] as? [[String: Any]] ?? [] {
                defer { state = (step["expect"] as? [String: Any])?["state"] as? [String: Any] }
                guard let s = state, let action = step["action"] as? [String: Any], action["type"] as? String == "expire_loss",
                      let qty = int64(action["qty"]),
                      let e = ((step["expect"] as? [String: Any])?["entries"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "expire_loss" }),
                      let base = try? ProductPrivate(productId: uuid(1), stockQty: try XCTUnwrap(int64(s["q"])), stockValueFen: Fen(try XCTUnwrap(int64(s["v"]))),
                                                     lastCostFen: int64(s["c"]).map(Fen.init), costKnown: s["k"] as? Bool ?? false, stockVer: 1)
                else { continue }
                let got = try ExpiryLoss.estimate(base, qty: qty)
                if e["cost_missing"] as? Bool == true { XCTAssertNil(got, c["id"] as? String ?? "?") } else {
                    XCTAssertEqual(got?.raw, int64(e["cogs_fen"]), c["id"] as? String ?? "?")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 2)
        // 库存不为正：按 c 算；进价不知道：没有
        let neg = try ProductPrivate(productId: uuid(1), stockQty: -2, stockValueFen: Fen(-400), lastCostFen: Fen(200), costKnown: true, stockVer: 1)
        XCTAssertEqual(try ExpiryLoss.estimate(neg, qty: 3)?.raw, 600)
        let unknown = try ProductPrivate(productId: uuid(1), stockQty: 5, stockValueFen: .zero, lastCostFen: nil, costKnown: false, stockVer: 1)
        XCTAssertNil(try ExpiryLoss.estimate(unknown, qty: 3))
        // 扔的比账上多：多出来的按平均进价
        let seven = try ProductPrivate(productId: uuid(1), stockQty: 2, stockValueFen: Fen(1960), lastCostFen: Fen(980), costKnown: true, stockVer: 1)
        XCTAssertEqual(try ExpiryLoss.estimate(seven, qty: 3)?.raw, 2940)
    }

    // MARK: 收银员

    func testCashierHasNoLotsAndCannotHandle() throws {
        let db = try db(.cashier)
        XCTAssertTrue(try db.expiryBoard(today: Self.today).isEmpty)
        let fake = ExpiryItem(lotId: Self.beerLot, productId: Self.beer, name: "青岛啤酒 500ml", unit: "罐", imageVer: 0,
                              expiryDate: try CalendarDate("2026-11-25"), qtyLeft: 1, handleVer: 0, snoozedUntil: nil, daysLeft: 6)
        XCTAssertInvalid(try db.handleExpiry(fake, choice: .discard, actualQty: 1))
        XCTAssertInvalid(try db.handleExpiry(fake, choice: .snooze, actualQty: 1))
        XCTAssertTrue(try db.allOutbox().isEmpty)
    }
}
