import Foundation
import XCTest
@testable import ShopCore

/// S18 新商品登记（04a / 04b / 04c / 25e）和整件码（05）在本地库这一层的验收：
/// 一个事务写商品、条码、op；整件码的数量与价格换算和 `PackConversion` / 契约逐分一致。
final class RegistrationTests: XCTestCase {
    static let store = DemoSeed.storeId
    static let newCode = "6924743919211"      // 04a 稿子：乐事薯片
    static let packCode = "6925303770099"     // 05：可乐的另一个整箱码（演示数据里没有）
    static let colaId = UUID(uuidString: "5EED0000-0000-4000-8000-000000000204")!   // 可口可乐 330ml，单罐 ¥3.00

    func db(_ role: Role) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: uuid(0xD18), storeId: Self.store, role: role, tokenRef: "t18",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    func payload(_ item: OutboxItem) throws -> [String: Any] {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: item.opJSON) as? [String: Any])
        return try XCTUnwrap(obj["payload"] as? [String: Any])
    }

    func assertSchemaValid(_ db: LocalDB, file: StaticString = #filePath, line: UInt = #line) throws {
        for item in try db.allOutbox() {
            XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(item.opJSON)), [],
                           String(decoding: item.opJSON, as: UTF8.self), file: file, line: line)
        }
    }

    // MARK: - 04a「存好，接着卖」（家用）

    func testFamilyQuickSaveWritesProductBarcodeAndFullUpsert() throws {
        let db = try db(.family)
        let reg = try NewProduct(barcode: Self.newCode, name: " 乐事薯片 原味 70g ", priceFen: Fen(750), baseUnit: "包")
        let conv = try db.registerProduct(reg)
        XCTAssertEqual(conv.product.name, "乐事薯片 原味 70g")
        XCTAssertEqual(try conv.unitPrice(), Fen(750))
        XCTAssertEqual(conv.packQty, 1)
        XCTAssertEqual(try db.lookup(barcode: Self.newCode), conv, "登记完扫这个码就能卖")
        XCTAssertFalse(conv.product.needsReview)
        let ops = try db.pendingOps()
        XCTAssertEqual(ops.map(\.type), [.productUpsert])
        let p = try payload(ops[0])
        XCTAssertEqual(p["quick"] as? Bool, false)
        XCTAssertEqual(p["base_unit"] as? String, "包")
        XCTAssertEqual(int64(p["price_fen"]), 750)
        XCTAssertEqual(p["barcode"] as? String, Self.newCode)
        // 家用登记后本地有一份零库存、进价未知的基线，显示库存 0
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, 0)
        XCTAssertEqual(try db.productPrivate(conv.product.id)?.costKnown, false)
        try assertSchemaValid(db)
    }

    /// 登记后进篮子、记账：和别的商品同一条路，卖价逐分不变
    func testRegisteredProductSellsAtEnteredPrice() throws {
        let db = try db(.family)
        let conv = try db.registerProduct(try NewProduct(barcode: Self.newCode, name: "乐事薯片 原味 70g", priceFen: Fen(750)))
        var b = Basket()
        try b.add(conv); try b.add(conv)
        XCTAssertEqual(try b.listTotal(), Fen(1500))
        let sale = try db.recordSale(b)
        XCTAssertEqual(sale.lines.first?.unitPriceFen, Fen(750))
        XCTAssertEqual(try db.pendingOps().map(\.type), [.productUpsert, .saleBatch], "登记在卖出前面（§4.4）")
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, -2)
    }

    // MARK: - 04b 进价和库存、保质期

    func testSecondStepQueuesOfflineOpeningWithoutCost() throws {
        let db = try db(.family)
        let reg = try NewProduct(barcode: Self.newCode, name: "乐事薯片 原味 70g", priceFen: Fen(750), baseUnit: "包",
                                 opening: try .init(countedQty: 12, unitCostFen: nil))
        XCTAssertTrue(reg.missingCostWarning, "填了库存没填进价：黄字提醒")
        let conv = try db.registerProduct(reg)
        let ops = try db.pendingOps()
        XCTAssertEqual(ops.map(\.type), [.productUpsert, .opening])
        let o = try payload(ops[1])
        XCTAssertEqual(int64(o["counted_qty"]), 12)
        XCTAssertNil(o["unit_cost_fen"], "没填进价 ≠ 零成本（§5.2）")
        XCTAssertNil(o["base_ver"], "新商品第二步的期初不带 base_ver（§5.6 第 3 条）")
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, 12)
        let e = try XCTUnwrap(try db.entries().first)
        XCTAssertEqual(e.type, .opening)
        XCTAssertEqual(e.qtyDelta, 12)
        try assertSchemaValid(db)
    }

    func testSecondStepWithCostAndExpiry() throws {
        let db = try db(.family)
        let expiry = try ExpirySettings(trackExpiry: true, expiryWarnDays: 15)
        let reg = try NewProduct(barcode: Self.newCode, name: "乐事薯片 原味 70g", priceFen: Fen(750), baseUnit: "包",
                                 expiry: expiry,
                                 opening: try .init(countedQty: 12, unitCostFen: Fen(520), expiryDate: try CalendarDate("2027-05-20")))
        XCTAssertFalse(reg.missingCostWarning)
        let conv = try db.registerProduct(reg)
        XCTAssertTrue(conv.product.trackExpiry)
        let ops = try db.pendingOps()
        let u = try payload(ops[0]), o = try payload(ops[1])
        XCTAssertEqual(u["track_expiry"] as? Bool, true)
        XCTAssertEqual(int64(u["expiry_warn_days"]), 15)
        XCTAssertEqual(int64(o["unit_cost_fen"]), 520)
        XCTAssertEqual(o["expiry_date"] as? String, "2027-05-20")
        XCTAssertEqual(try db.productPrivate(conv.product.id)?.expiryWarnDays, 15)
        try assertSchemaValid(db)
    }

    /// 「不知道，先不填」：管保质期，但这批没有到期日
    func testExpiryTrackedButDateUnknown() throws {
        let db = try db(.family)
        let reg = try NewProduct(barcode: Self.newCode, name: "乐事", priceFen: Fen(750), baseUnit: "包",
                                 expiry: try ExpirySettings(trackExpiry: true, expiryWarnDays: 7),
                                 opening: try .init(countedQty: 3, unitCostFen: Fen(0), expiryDate: nil))
        try db.registerProduct(reg)
        let o = try payload(try db.pendingOps()[1])
        XCTAssertNil(o["expiry_date"])
        XCTAssertEqual(int64(o["unit_cost_fen"]), 0, "明确填 0 是零成本，照发")
        XCTAssertFalse(reg.missingCostWarning)
    }

    func testCostWithoutQuantityStillRecordsZeroOpening() throws {
        let db = try db(.family)
        let reg = try NewProduct(barcode: Self.newCode, name: "乐事", priceFen: Fen(750), baseUnit: "包",
                                 opening: try .init(countedQty: 0, unitCostFen: Fen(520)))
        XCTAssertFalse(reg.missingCostWarning)
        try db.registerProduct(reg)
        let o = try payload(try db.pendingOps()[1])
        XCTAssertEqual(int64(o["counted_qty"]), 0)
        XCTAssertEqual(int64(o["unit_cost_fen"]), 520)
    }

    // MARK: - 04c 收银员

    func testCashierQuickRegistration() throws {
        let db = try db(.cashier)
        let conv = try db.registerProduct(try NewProduct(barcode: "6920152400319", name: "白象 老母鸡汤面", priceFen: Fen(450)),
                                          quick: true)
        XCTAssertTrue(conv.product.needsReview, "quick 登记一律待确认（§14 S04-5）")
        XCTAssertEqual(conv.product.baseUnit, "个", "quick 不带 base_unit，服务器默认「个」")
        let ops = try db.pendingOps()
        XCTAssertEqual(ops.map(\.type), [.productUpsert])
        let p = try payload(ops[0])
        XCTAssertEqual(p["quick"] as? Bool, true)
        XCTAssertEqual(Set(p.keys), ["product_id", "barcode", "name", "price_fen", "quick"], "收银员只发名称和卖价")
        XCTAssertNil(try db.productPrivate(conv.product.id), "收银员手机不存进价和库存")
        try assertSchemaValid(db)
    }

    func testCashierCannotFullRegisterOrOpenStock() throws {
        let db = try db(.cashier)
        XCTAssertInvalid(try db.registerProduct(try NewProduct(barcode: Self.newCode, name: "乐事", priceFen: Fen(750))))
        XCTAssertInvalid(try db.registerProduct(try NewProduct(barcode: Self.newCode, name: "乐事", priceFen: Fen(750),
                                                                opening: try .init(countedQty: 3)), quick: true))
        XCTAssertNil(try db.lookup(barcode: Self.newCode), "被拒的登记什么都不写")
        XCTAssertEqual(try db.pendingOps().count, 0)
    }

    // MARK: - 25e 断网：名称为空也能登记并卖出

    func testEmptyNameRegistersWithPlaceholderAndSells() throws {
        for (role, quick) in [(Role.family, false), (.cashier, true)] {
            let db = try db(role)
            let reg = try NewProduct(barcode: "6901028075831", name: "   ", priceFen: Fen(300))
            XCTAssertTrue(ProductNaming.isPlaceholder(reg.name))
            let conv = try db.registerProduct(reg, quick: quick)
            XCTAssertTrue(ProductNaming.isPlaceholder(conv.product.name))
            XCTAssertTrue(conv.product.name.hasSuffix("5831"), "占位名带条码尾号，记的账里分得清")
            var b = Basket()
            try b.add(conv)
            try db.recordSale(b)
            XCTAssertEqual(try db.pendingOps().map(\.type), [.productUpsert, .saleBatch])
            try assertSchemaValid(db)   // 契约要求名称至少 1 个字：占位名过得去
        }
        XCTAssertFalse(ProductNaming.isPlaceholder("乐事薯片"))
    }

    // MARK: - 条码：S14-5 统一字符集，整串不收、不截断

    func testBarcodeCharsetAndLengthRejectedWhole() throws {
        let db = try db(.family)
        for bad in ["6901-035", "69 01", "６９０１", "条码123", String(repeating: "1", count: 65), ""] {
            XCTAssertInvalid(try NewProduct(barcode: bad, name: "x", priceFen: Fen(1)), bad)
            XCTAssertFalse(NewProduct.isRegistrable(bad), bad)
        }
        XCTAssertTrue(NewProduct.isRegistrable(String(repeating: "A", count: 64)))
        XCTAssertTrue(NewProduct.isRegistrable("ABCabc123"), "大小写原样保留")
        let conv = try db.registerProduct(try NewProduct(barcode: "ABCabc123", name: "x", priceFen: Fen(1)))
        XCTAssertEqual(conv.barcode.barcode, "ABCabc123")
        XCTAssertNil(try db.lookup(barcode: "abcabc123"))
    }

    func testAlreadyRegisteredBarcodeIsRejected() throws {
        let db = try db(.family)
        XCTAssertInvalid(try db.registerProduct(try NewProduct(barcode: "6901234500011", name: "别的", priceFen: Fen(1))))
        XCTAssertEqual(try db.lookup(barcode: "6901234500011")?.product.name, "牛栏山二锅头 500ml", "原商品不变")
        XCTAssertEqual(try db.pendingOps().count, 0)
    }

    func testPriceLimits() throws {
        XCTAssertInvalid(try NewProduct(barcode: Self.newCode, name: "x", priceFen: Fen(Limits.maxFen + 1)))
        XCTAssertNoThrow(try NewProduct(barcode: Self.newCode, name: "x", priceFen: Fen(Limits.maxFen)))
        XCTAssertInvalid(try NewProduct.Opening(countedQty: Limits.maxBaseQty + 1))
        XCTAssertInvalid(try NewProduct.Opening(countedQty: 1, unitCostFen: Fen(Limits.maxFen + 1)))
    }

    // MARK: - 05 整件码：数量与价格换算和 ShopCore / 契约逐分一致

    func testLinkPackWithOwnPrice() throws {
        let db = try db(.family)
        let conv = try db.linkPack(try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 24,
                                                packPriceFen: Fen(6000)))
        XCTAssertEqual(try db.lookup(barcode: Self.packCode), conv)
        XCTAssertEqual(conv.packQty, 24)
        XCTAssertEqual(try conv.unitPrice(), Fen(6000))
        XCTAssertEqual(try conv.baseQty(packCount: 1), 24, "扫这个码按 24 个算")
        var b = Basket()
        try b.add(conv); try b.add(conv)
        XCTAssertEqual(try b.listTotal(), Fen(12000))
        XCTAssertEqual(try b.lines[0].baseQty(), 48)
        let before = try XCTUnwrap(try db.displayStock(Self.colaId)?.qty)
        try db.recordSale(b)
        XCTAssertEqual(try db.displayStock(Self.colaId)?.qty, before - 48)
        let link = try payload(try db.pendingOps()[0])
        XCTAssertEqual(try db.pendingOps()[0].type, .barcodeLink)
        XCTAssertEqual(int64(link["pack_qty"]), 24)
        XCTAssertEqual(link["unit_name"] as? String, "箱")
        XCTAssertEqual(int64(link["pack_price_fen"]), 6000)
        try assertSchemaValid(db)
    }

    /// 整箱价不填 = 单件卖价 × 换算数量（§14 S02-5 / S12-1），和 `PackConversion.unitPrice` 同一个口径
    func testLinkPackWithoutPriceUsesUnitTimesQty() throws {
        let db = try db(.family)
        let link = try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 24, packPriceFen: nil)
        XCTAssertEqual(try link.effectivePrice(unitPriceFen: Fen(300)), Fen(7200))
        let conv = try db.linkPack(link)
        XCTAssertEqual(try conv.unitPrice(), Fen(7200))
        XCTAssertNil(try payload(try db.pendingOps()[0])["pack_price_fen"], "不填就不带，服务器按单价 × 换算算")
        // 单价 × 换算超上限：不让存
        let big = try PackLink(barcode: "6925303770105", productId: Self.colaId, unitName: "箱", packQty: 9_999, packPriceFen: nil)
        XCTAssertInvalid(try big.effectivePrice(unitPriceFen: Fen(Limits.maxFen)))
        try assertSchemaValid(db)
    }

    func testLinkPackRejections() throws {
        let db = try db(.family)
        XCTAssertInvalid(try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 1, packPriceFen: nil),
                         "整件至少 2 个")
        XCTAssertInvalid(try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 10_000, packPriceFen: nil))
        XCTAssertInvalid(try PackLink(barcode: "6925-30", productId: Self.colaId, unitName: "箱", packQty: 24, packPriceFen: nil))
        XCTAssertInvalid(try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 24,
                                      packPriceFen: Fen(Limits.maxFen + 1)))
        // 已经挂在别的商品上：拒，不挪（§4.4）
        XCTAssertInvalid(try db.linkPack(try PackLink(barcode: "6901234500011", productId: Self.colaId, unitName: "箱", packQty: 24,
                                                      packPriceFen: nil)))
        // 商品不在本地
        XCTAssertInvalid(try db.linkPack(try PackLink(barcode: Self.packCode, productId: uuid(0xBAD), unitName: "箱", packQty: 24,
                                                      packPriceFen: nil)))
        XCTAssertEqual(try db.pendingOps().count, 0)
        let cashier = try self.db(.cashier)
        XCTAssertInvalid(try cashier.linkPack(try PackLink(barcode: Self.packCode, productId: Self.colaId, unitName: "箱", packQty: 24,
                                                           packPriceFen: nil)), "收银员不能挂整件码")
        XCTAssertNil(try cashier.lookup(barcode: Self.packCode))
    }
}
