import XCTest
@testable import ShopCore

/// 设计稿 03 的三样东西
enum Fixture03 {
    static let erguotou = try! Product(id: uuid(0x201), name: "牛栏山二锅头 500ml", baseUnit: "瓶", priceFen: Fen(2500))
    static let tsingtao = try! Product(id: uuid(0x202), name: "青岛啤酒 500ml", baseUnit: "罐", priceFen: Fen(600))
    static let noodle = try! Product(id: uuid(0x203), name: "康师傅红烧牛肉面", baseUnit: "桶", priceFen: Fen(450))
    static func conv(_ p: Product, _ code: String) -> PackConversion {
        try! PackConversion(product: p, barcode: try! BarcodeRecord(barcode: code, productId: p.id, unitName: p.baseUnit))
    }
    static let erguotouCode = conv(erguotou, "6901234500011")
    static let tsingtaoCode = conv(tsingtao, "6901035600016")
    static let noodleCode = conv(noodle, "6902514300011")
}

final class BasketTests: XCTestCase {
    /// 验收：设计稿 03 的购物篮合计 ¥53.50（二锅头 1 × 25.00、青岛 4 × 6.00、方便面 1 × 4.50，一共 6 件）
    func testDesign03BasketTotal() throws {
        var b = Basket()
        try b.add(Fixture03.erguotouCode)
        for _ in 0..<4 { try b.add(Fixture03.tsingtaoCode) }
        try b.add(Fixture03.noodleCode)
        XCTAssertEqual(b.lines.count, 3)
        XCTAssertEqual(try b.lines.map { try $0.listAmount() }, [Fen(2500), Fen(2400), Fen(450)])
        XCTAssertEqual(try b.listTotal(), Fen(5350))
        XCTAssertEqual(try b.listTotal().yuanString, "¥53.50")
        XCTAssertEqual(b.itemCount, 6)
        XCTAssertEqual(try b.paidTotal(), Fen(5350))

        // 抹到 ¥53 → 24.76 / 23.78 / 4.46（设计稿 08）
        try b.setPaid(Fen(5300))
        XCTAssertEqual(try b.allocation().amountFen, [2476, 2378, 446])
        XCTAssertFalse(try b.needsPaidConfirmation())
        // 「不抹了」恢复原价
        try b.setPaid(nil)
        XCTAssertEqual(try b.paidTotal(), Fen(5350))
    }

    func testSameCodeTwiceIsQuantityTwoAndStepperToZeroRemoves() throws {
        var b = Basket()
        try b.add(Fixture03.noodleCode)
        try b.add(Fixture03.noodleCode)
        XCTAssertEqual(b.lines.count, 1)
        XCTAssertEqual(b.lines[0].packCount, 2)
        try b.setCount(at: 0, 0)
        XCTAssertTrue(b.isEmpty)
    }

    /// 同一商品的两个单件码算一行，同一卖价（§3.2）
    func testTwoSingleCodesOfSameProductMerge() throws {
        var b = Basket()
        try b.add(Fixture03.noodleCode)
        try b.add(Fixture03.conv(Fixture03.noodle, "6902514300028"))
        XCTAssertEqual(b.lines.count, 1)
        XCTAssertEqual(b.lines[0].packCount, 2)
        XCTAssertEqual(try b.listTotal(), Fen(900))
    }

    func testZeroPriceBasketCannotChangePaid() throws {
        let gift = try Product(id: uuid(0x299), name: "赠品袋", priceFen: .zero)
        var b = Basket()
        XCTAssertFalse(try b.canChangePaid())
        try b.add(Fixture03.conv(gift, "2000000000001"))
        XCTAssertFalse(try b.canChangePaid())
        XCTAssertInvalid(try b.setPaid(Fen(100)))
        XCTAssertEqual(try b.allocation().amountFen, [0])
        try b.add(Fixture03.noodleCode)
        XCTAssertTrue(try b.canChangePaid())
    }

    /// 实收低于原价七折或高于原价要二次确认（§5.1、设计稿 28）
    func testPaidConfirmationThresholds() throws {
        var b = Basket()
        try b.add(Fixture03.erguotouCode, packCount: 4)   // ¥100.00
        try b.setPaid(Fen(7000)); XCTAssertFalse(try b.needsPaidConfirmation())   // 恰好七折
        try b.setPaid(Fen(6999)); XCTAssertTrue(try b.needsPaidConfirmation())
        try b.setPaid(Fen(10000)); XCTAssertFalse(try b.needsPaidConfirmation())
        try b.setPaid(Fen(10001)); XCTAssertTrue(try b.needsPaidConfirmation())   // 多收
        XCTAssertInvalid(try b.setPaid(Fen(19_999_999_801)))
    }

    func testBasketRejectsOverLimitAndStaysUnchanged() throws {
        var b = Basket()
        try b.add(Fixture03.erguotouCode)
        XCTAssertInvalid(try b.setCount(at: 0, 100_000))          // 件数上限
        XCTAssertEqual(b.lines[0].packCount, 1)
        XCTAssertInvalid(try b.setCount(at: 0, 40_000))           // 单行金额 40,000 × 2500 超上限
        XCTAssertEqual(b.lines[0].packCount, 1)
        var many = Basket()
        for i in 0..<200 {
            let p = try Product(id: uuid(0x1000 + i), name: "商品\(i)", priceFen: Fen(1))
            try many.add(Fixture03.conv(p, "69\(100000 + i)"))
        }
        let extra = try Product(id: uuid(0x9999), name: "多一行", priceFen: Fen(1))
        XCTAssertInvalid(try many.add(Fixture03.conv(extra, "6999999")))
        XCTAssertEqual(many.lines.count, 200)
    }

    func testMakeSaleBatch() throws {
        var b = Basket()
        try b.add(Fixture03.erguotouCode, lineId: uuid(0x101))
        try b.setPaid(Fen(2000))
        let p = try b.makeSaleBatch(batchId: uuid(0x301))
        XCTAssertEqual(p.paidTotalFen, Fen(2000))
        XCTAssertEqual(p.lines.map(\.entryId), [uuid(0x101)])
        XCTAssertEqual(p.lines[0].unitPriceFen, Fen(2500))
        XCTAssertInvalid(try Basket().makeSaleBatch())
    }
}

final class PackConversionTests: XCTestCase {
    static let cola = try! Product(id: uuid(0x210), name: "可口可乐 330ml", baseUnit: "罐", priceFen: Fen(300))
    static let colaCan = try! BarcodeRecord(barcode: "6928804011111", productId: cola.id, unitName: "罐")
    static let colaCase = try! BarcodeRecord(barcode: "16928804011118", productId: cola.id, packQty: 24, unitName: "箱", packPriceFen: Fen(6500))

    /// 验收：扫整箱码换算成 24 个基本单位
    func testCaseCodeConvertsTo24BaseUnits() throws {
        let conv = try PackConversion(product: Self.cola, barcode: Self.colaCase)
        XCTAssertEqual(conv.packQty, 24)
        XCTAssertEqual(try conv.baseQty(packCount: 1), 24)
        XCTAssertEqual(try conv.unitPrice(), Fen(6500))         // 整件卖用整件码自己的价
        XCTAssertEqual(conv.unitLabel, "箱（24 罐）")

        var b = Basket()
        try b.add(conv)
        try b.add(try PackConversion(product: Self.cola, barcode: Self.colaCan))
        XCTAssertEqual(b.lines.count, 2, "单件和整箱是两行")
        XCTAssertEqual(try b.lines[0].baseQty(), 24)
        XCTAssertEqual(try b.lines[1].baseQty(), 1)
        XCTAssertEqual(try b.listTotal(), Fen(6800))
    }

    /// 必过向量（设计稿 06a）：可乐 5 箱 × ¥48 → 一共 ¥240.00，入账 120 罐，每罐 ¥2.00
    func testStockInCaseConversion() throws {
        let conv = try PackConversion(product: Self.cola, barcode: Self.colaCase)
        let s = try StockInPayload(entryId: uuid(1), conversion: conv, packCount: 5, unitCostFen: Fen(4800))
        XCTAssertEqual(s.baseQty, 120)
        XCTAssertEqual(s.totalFen.yuanString, "¥240.00")
        XCTAssertEqual(try s.batchUnitCost(), Fen(200))
        XCTAssertEqual(s.packQty, 24)
        XCTAssertEqual(s.packCount, 5)
    }

    /// 5 条 × ¥400（1 条 = 10 包）：op 带的是件数和每条单价，入账 50 包
    func testStockInCartons() throws {
        let cig = try Product(id: uuid(0x220), name: "中华（硬）", baseUnit: "包", priceFen: Fen(4500))
        let carton = try BarcodeRecord(barcode: "6901028000000", productId: cig.id, packQty: 10, unitName: "条", packPriceFen: Fen(45000))
        let s = try StockInPayload(entryId: uuid(1), conversion: try PackConversion(product: cig, barcode: carton),
                                   packCount: 5, unitCostFen: Fen(40000))
        XCTAssertEqual(s.baseQty, 50)
        XCTAssertEqual(s.totalFen, Fen(200_000))
        XCTAssertEqual(try s.batchUnitCost(), Fen(4000))
    }

    /// 整件码没设价时按「单件卖价 × 换算数量」（§14 S02-5）
    func testPackPriceFallback() throws {
        let noPrice = try BarcodeRecord(barcode: "26928804011115", productId: Self.cola.id, packQty: 6, unitName: "提")
        XCTAssertEqual(try PackConversion(product: Self.cola, barcode: noPrice).unitPrice(), Fen(1800))
        let other = try Product(id: uuid(0x777), name: "别的", priceFen: Fen(1))
        XCTAssertInvalid(try PackConversion(product: other, barcode: Self.colaCan))
    }

    func testUnitCostDisplay() throws {
        // 6 包货值 242.80，再进 5 条 × 400 → 56 包、货值 2242.80，平均 40.05（§5.2 必过向量的显示部分）
        let pp = ProductPrivate(productId: uuid(1), stockQty: 56, stockValueFen: Fen(224_280), lastCostFen: Fen(4000), costKnown: true)
        XCTAssertEqual(try pp.unitCost(), Fen(4005))
        let unknown = ProductPrivate(productId: uuid(1), stockQty: 10)
        XCTAssertNil(try unknown.unitCost())
    }
}
