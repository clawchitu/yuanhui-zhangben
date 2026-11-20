import XCTest
@testable import ShopCore

final class OpsSchemaTests: XCTestCase {
    static var validator: SchemaValidator { SchemaValidator(root: try! loadJSON("contracts/ops.schema.json") as! [String: Any]) }

    /// 校验器本身可信：contracts/examples 的正例全过、反例全拒
    func testValidatorAgreesWithContractExamples() throws {
        let valid = try loadJSON("contracts/examples/ops-valid.json") as! [Any]
        XCTAssertGreaterThan(valid.count, 0)
        for (i, op) in valid.enumerated() {
            XCTAssertEqual(Self.validator.validate(JV(op)), [], "ops-valid[\(i)]")
        }
        let invalid = try loadJSON("contracts/examples/ops-invalid.json") as! [[String: Any]]
        XCTAssertGreaterThan(invalid.count, 0)
        for c in invalid {
            XCTAssertFalse(Self.validator.validate(JV(c["op"]!)).isEmpty, "ops-invalid 应被拒：\(c["why"] ?? "")")
        }
    }

    /// 每种 op（及其变体）的样本
    static func samples() throws -> [(String, Op)] {
        let t = Date(timeIntervalSince1970: 1_795_000_000)   // 固定时间，输出确定
        func op(_ n: Int, _ p: any OpPayload) -> Op { Op(id: uuid(n), occurredAt: t, payload: p) }
        let p = uuid(0x201)
        var b = Basket()
        try b.add(Fixture03.erguotouCode, lineId: uuid(0x101))
        try b.add(Fixture03.tsingtaoCode, packCount: 4, lineId: uuid(0x102))
        try b.add(Fixture03.noodleCode, lineId: uuid(0x103))
        try b.setPaid(Fen(5300))
        let caseCode = try BarcodeRecord(barcode: "16928804011118", productId: p, packQty: 24, unitName: "箱", packPriceFen: Fen(6500))
        let single = try BarcodeRecord(barcode: "6928804011111", productId: p, unitName: "罐")
        let exp = try ExpirySettings(trackExpiry: true, expiryWarnDays: 7, shelfLifeMonths: 6)
        return [
            ("sale_batch", op(1, try b.makeSaleBatch(batchId: uuid(0x301)))),
            ("sale_batch 全零", op(2, try SaleBatchPayload(batchId: uuid(0x302), paidTotalFen: .zero, lines: [
                try SaleLine(entryId: uuid(0x104), productId: p, barcode: "2000000000001", name: "赠品", unitName: "个",
                             packQty: 1, packCount: 1, unitPriceFen: .zero)]))),
            ("void batch", op(3, VoidPayload(target: .batch(uuid(0x301))))),
            ("void entry", op(4, VoidPayload(target: .entry(uuid(0x101))))),
            ("product_upsert quick", op(5, try ProductUpsertPayload.quick(productId: p, barcode: "6920202888883", name: "怡宝", priceFen: Fen(200)))),
            ("product_upsert full 最少", op(6, try ProductUpsertPayload.full(productId: p, barcode: "6920202888890", name: "可乐", priceFen: Fen(300), baseUnit: "罐"))),
            ("product_upsert full 全字段", op(7, try ProductUpsertPayload.full(productId: p, barcode: "6920202888890", name: "牛奶", priceFen: Fen(500), baseUnit: "盒", expiry: exp, lowAt: 3))),
            ("product_upsert full 无保质期月数", op(8, try ProductUpsertPayload.full(productId: p, barcode: "1", name: "x", priceFen: .zero, baseUnit: "个",
                                                                              expiry: try ExpirySettings(trackExpiry: false), lowAt: 0))),
            ("product_edit 一项", op(9, try ProductEditPayload(productId: p, priceFen: .set(Fen(2600))))),
            ("product_edit 全部", op(10, try ProductEditPayload(productId: p, name: .set("新名字"), priceFen: .set(.zero), baseUnit: .set("瓶"),
                                                              lowAt: .set(5), trackExpiry: .set(true), expiryWarnDays: .set(10),
                                                              shelfLifeMonths: .set(12), archived: .set(true)))),
            ("product_edit 清空", op(11, try ProductEditPayload(productId: p, lowAt: .set(nil), shelfLifeMonths: .set(nil)))),
            ("barcode_link 单件", op(12, BarcodeLinkPayload(single))),
            ("barcode_link 整箱", op(13, BarcodeLinkPayload(caseCode))),
            ("barcode_link 整件不带价", op(26, BarcodeLinkPayload(try BarcodeRecord(barcode: "26928804011115", productId: p, packQty: 6, unitName: "提")))),
            ("barcode_unlink", op(14, try BarcodeUnlinkPayload(barcode: "16928804011118", productId: p))),
            ("stock_in", op(15, try StockInPayload(entryId: uuid(0x105), conversion: try PackConversion(product: PackConversionTests.cola, barcode: PackConversionTests.colaCase),
                                                   packCount: 5, unitCostFen: Fen(4800)))),
            ("stock_in 到期日", op(16, try StockInPayload(entryId: uuid(0x106), productId: p, barcode: "1", packQty: 1, packCount: 3,
                                                       unitCostFen: Fen(100), expiryDate: try CalendarDate("2027-05-12")))),
            ("opening 没填进价", op(17, try OpeningPayload(entryId: uuid(0x107), productId: p, countedQty: 10))),
            ("opening 全字段", op(18, try OpeningPayload(entryId: uuid(0x108), productId: p, countedQty: 0, unitCostFen: .zero,
                                                       expiryDate: try CalendarDate("2027-11-19"), baseVer: 3, baseQty: -2))),
            ("product_review_complete", op(19, try ProductReviewCompletePayload(entryId: uuid(0x109), productId: p, unitCostFen: .zero,
                                                                               countedQty: 4, baseVer: 0))),
            ("product_review_complete 全字段", op(20, try ProductReviewCompletePayload(entryId: uuid(0x10a), productId: p, unitCostFen: Fen(150),
                                                                                      countedQty: 4, baseVer: 2, baseQty: 5, expiry: exp,
                                                                                      expiryDate: try CalendarDate("2027-01-31")))),
            ("count", op(21, try CountPayload(entryId: uuid(0x10b), productId: p, countedQty: 10, baseQty: 8, baseVer: 7))),
            ("expiry_dispose", op(22, try ExpiryDisposePayload(lotId: uuid(0x401), handleVer: 1, actualQty: 3, action: .discard, entryId: uuid(0x10c)))),
            ("expiry_dispose sold_out", op(23, try ExpiryDisposePayload(lotId: uuid(0x401), handleVer: 0, actualQty: 0, action: .soldOut, entryId: uuid(0x10d)))),
            ("expiry_dispose return", op(24, try ExpiryDisposePayload(lotId: uuid(0x401), handleVer: 2, actualQty: 9_999_999, action: .return, entryId: uuid(0x10e)))),
            ("lot_snooze", op(25, try LotSnoozePayload(lotId: uuid(0x401), handleVer: 1, actualQty: 2, days: 3))),
        ]
    }

    /// 验收：每种 op 编码出的 JSON 通过 ops.schema.json 校验
    func testEveryOpTypeEncodesToSchemaValidJSON() throws {
        let samples = try Self.samples()
        XCTAssertEqual(Set(samples.map(\.1.type)), Set(OpType.allCases), "每种 op 都有样本")
        for (name, op) in samples {
            let data = op.encoded()
            let parsed = try JV.parse(data)
            XCTAssertEqual(Self.validator.validate(parsed), [], "\(name)：\(String(decoding: data, as: UTF8.self))")
        }
    }

    func testEncodingIsDeterministicIntegerOnlyAndLowercase() throws {
        func hasDouble(_ v: JV) -> Bool {
            switch v {
            case .double: return true
            case .object(let o): return o.values.contains(where: hasDouble)
            case .array(let a): return a.contains(where: hasDouble)
            default: return false
            }
        }
        for (name, op) in try Self.samples() {
            XCTAssertEqual(op.encoded(), op.encoded(), name)
            XCTAssertFalse(hasDouble(try JV.parse(op.encoded())), "\(name) 金额和数量都是整数")
            let s = String(decoding: op.encoded(), as: UTF8.self)
            XCTAssertTrue(s.contains("\"id\":\"\(op.id.uuidString.lowercased())\""), name)
        }
        let s = String(decoding: try Self.samples()[0].1.encoded(), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix(#"{"id":"00000000-0000-4000-8000-000000000001","type":"sale_batch","occurred_at":""#), s)
        XCTAssertTrue(s.contains(#""paid_total_fen":5300"#))
        XCTAssertTrue(s.contains(#""unit_price_fen":2500"#))
        XCTAssertEqual(Op.formatTimestamp(Date(timeIntervalSince1970: 1_795_000_000)), "2026-11-18T19:06:40.000+08:00")
    }

    func testQuickUpsertCarriesNoFamilyFields() throws {
        let q = try ProductUpsertPayload.quick(productId: uuid(1), barcode: "1", name: "x", priceFen: Fen(1))
        guard case .object(let kv) = q.json else { return XCTFail() }
        XCTAssertEqual(kv.map(\.0), ["product_id", "barcode", "name", "price_fen", "quick"])
    }

    /// §14 S02-5 / S12-1：整件码可以不带价，编码出的 op 没有 pack_price_fen 这个键且通过 schema；
    /// 读价按「单件卖价 × 换算数量」兜底。单件码带价在构造时就拒。
    func testPackLinkWithoutPriceAllowed() throws {
        let rec = try BarcodeRecord(barcode: "26928804011115", productId: PackConversionTests.cola.id, packQty: 6, unitName: "提")
        let payload = BarcodeLinkPayload(rec)
        guard case .object(let kv) = payload.json else { return XCTFail() }
        XCTAssertEqual(kv.map(\.0), ["barcode", "product_id", "pack_qty", "unit_name"])
        let op = Op(id: uuid(1), occurredAt: Date(timeIntervalSince1970: 1_795_000_000), payload: payload)
        XCTAssertEqual(Self.validator.validate(try JV.parse(op.encoded())), [])
        XCTAssertEqual(try PackConversion(product: PackConversionTests.cola, barcode: rec).unitPrice(), Fen(1800))   // ¥3.00 × 6
        XCTAssertInvalid(try BarcodeRecord(barcode: "1", productId: uuid(1), packQty: 1, unitName: "瓶", packPriceFen: Fen(200)))
    }

    func testOnlineOnlyOps() {
        XCTAssertEqual(Set(OpType.allCases.filter(\.onlineOnly)), [.count, .productReviewComplete])
    }
}
