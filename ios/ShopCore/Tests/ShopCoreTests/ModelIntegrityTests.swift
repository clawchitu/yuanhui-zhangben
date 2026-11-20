import XCTest
@testable import ShopCore

/// Codex P2：模型和 payload 拿到手就是合法的，构造之后改不坏，解码也绕不过校验。
final class ModelIntegrityTests: XCTestCase {
    /// 构造后不能直接赋值：Models / Payloads 里不许有公开的存储型 `var`（计算属性和 `private(set)` 不算）。
    /// Swift 里给 `let` 赋值编译不过，没法写运行时的负例，所以扫源码兜住以后有人改回 `var`。
    func testNoPublicMutableStoredFields() throws {
        let stored = try NSRegularExpression(pattern: #"^\s*public\s+var\s+\w+\s*:[^{]*$"#)
        for f in ["Models/Models.swift", "Ops/Payloads.swift", "Ops/Op.swift", "Basket/PackConversion.swift"] {
            let text = try String(contentsOf: shopCoreSources.appendingPathComponent(f), encoding: .utf8)
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                if stored.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    XCTFail("\(f):\(n + 1) 公开可变的存储字段会绕过构造器校验：\(raw)")
                }
            }
        }
    }

    /// 要改商品只能走 `with(...)`，不合法就抛错、原值不变
    func testProductWithRevalidates() throws {
        let p = try Product(id: uuid(1), name: "可乐", baseUnit: "罐", priceFen: Fen(300))
        XCTAssertInvalid(try p.with(priceFen: Fen(-1)))
        XCTAssertInvalid(try p.with(priceFen: Fen(Limits.maxFen + 1)))
        XCTAssertInvalid(try p.with(name: ""))
        XCTAssertInvalid(try p.with(name: String(repeating: "长", count: Limits.maxNameLength + 1)))
        XCTAssertInvalid(try p.with(baseUnit: String(repeating: "个", count: Limits.maxUnitLength + 1)))
        XCTAssertInvalid(try p.with(imageVer: -1))
        XCTAssertEqual(p.priceFen, Fen(300))
        let q = try p.with(priceFen: Fen(350), archived: true)
        XCTAssertEqual(q.priceFen, Fen(350)); XCTAssertTrue(q.archived); XCTAssertEqual(q.id, p.id); XCTAssertEqual(q.name, "可乐")
    }

    /// product_edit 构造时就把非法值和「一个都不改」拒掉；字段只读，构造后没有别的路改
    func testProductEditRejectsInvalidAtConstruction() {
        XCTAssertInvalid(try ProductEditPayload(productId: uuid(1)))
        XCTAssertInvalid(try ProductEditPayload(productId: uuid(1), priceFen: .set(Fen(-1))))
        XCTAssertInvalid(try ProductEditPayload(productId: uuid(1), name: .set("")))
        XCTAssertInvalid(try ProductEditPayload(productId: uuid(1), lowAt: .set(Limits.maxLowAt + 1)))
        XCTAssertInvalid(try ProductEditPayload(productId: uuid(1), shelfLifeMonths: .set(0)))
    }

    func testProductPrivateValidates() throws {
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), stockQty: 5, stockValueFen: Fen(100)))        // k 假但 v ≠ 0
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), stockQty: 5, stockValueFen: Fen(-1), lastCostFen: Fen(1), costKnown: true))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), stockQty: -2, stockValueFen: Fen(-500), lastCostFen: Fen(300), costKnown: true))
        XCTAssertNoThrow(try ProductPrivate(productId: uuid(1), stockQty: -2, stockValueFen: Fen(-600), lastCostFen: Fen(300), costKnown: true))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), lastCostFen: Fen(Limits.maxFen + 1)))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), stockVer: -1))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), lowAt: -1))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), expiryWarnDays: Limits.maxExpiryWarnDays + 1))
        XCTAssertInvalid(try ProductPrivate(productId: uuid(1), shelfLifeMonths: 0))
    }

    // MARK: 解码走校验构造器

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func XCTAssertDecodeInvalid<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertInvalid(try decode(type, json), json, file: file, line: line)
    }

    func testCodableRoundTrip() throws {
        let p = try Product(id: uuid(1), name: "可乐", baseUnit: "罐", priceFen: Fen(300), imageVer: 2)
        XCTAssertEqual(try JSONDecoder().decode(Product.self, from: try JSONEncoder().encode(p)), p)
        let r = try BarcodeRecord(barcode: "16928804011118", productId: uuid(1), packQty: 24, unitName: "箱", packPriceFen: Fen(6500))
        XCTAssertEqual(try JSONDecoder().decode(BarcodeRecord.self, from: try JSONEncoder().encode(r)), r)
        let n = try BarcodeRecord(barcode: "26928804011115", productId: uuid(1), packQty: 6, unitName: "提")
        XCTAssertEqual(try JSONDecoder().decode(BarcodeRecord.self, from: try JSONEncoder().encode(n)), n)
        let pp = try ProductPrivate(productId: uuid(1), stockQty: 56, stockValueFen: Fen(224_280), lastCostFen: Fen(4000), costKnown: true)
        XCTAssertEqual(try JSONDecoder().decode(ProductPrivate.self, from: try JSONEncoder().encode(pp)), pp)
    }

    func testDecodingOutOfRangeProductRejected() {
        let id = uuid(1).uuidString
        func product(price: Int64 = 300, name: String = "可乐", unit: String = "罐", imageVer: Int = 0) -> String {
            #"{"id":"\#(id)","name":"\#(name)","baseUnit":"\#(unit)","priceFen":\#(price),"needsReview":false,"trackExpiry":false,"imageVer":\#(imageVer),"archived":false}"#
        }
        XCTAssertNoThrow(try decode(Product.self, product()))
        XCTAssertNoThrow(try decode(Product.self, product(price: Limits.maxFen)))
        XCTAssertDecodeInvalid(Product.self, product(price: Limits.maxFen + 1))
        XCTAssertDecodeInvalid(Product.self, product(price: -1))
        XCTAssertDecodeInvalid(Product.self, product(name: ""))
        XCTAssertDecodeInvalid(Product.self, product(unit: String(repeating: "个", count: Limits.maxUnitLength + 1)))
        XCTAssertDecodeInvalid(Product.self, product(imageVer: -1))
    }

    func testDecodingInvalidBarcodeRecordRejected() {
        let id = uuid(1).uuidString
        func rec(_ packQty: Int64, price: Int64? = nil, barcode: String = "1") -> String {
            let p = price.map { #","packPriceFen":\#($0)"# } ?? ""
            return #"{"barcode":"\#(barcode)","productId":"\#(id)","packQty":\#(packQty),"unitName":"箱"\#(p)}"#
        }
        XCTAssertNoThrow(try decode(BarcodeRecord.self, rec(Limits.maxPackQty, price: 100)))
        XCTAssertNoThrow(try decode(BarcodeRecord.self, rec(24)))                              // 整件码不带价可以（S12-1）
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(Limits.maxPackQty + 1, price: 100))     // packQty = 10000
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(0))
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(1, price: 200))                         // 单件码带整件价
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(24, price: Limits.maxFen + 1))
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(24, price: -1))
        XCTAssertDecodeInvalid(BarcodeRecord.self, rec(24, barcode: ""))
    }

    func testDecodingInvalidProductPrivateRejected() {
        let id = uuid(1).uuidString
        func pp(qty: Int64 = 0, value: Int64 = 0, cost: Int64? = nil, known: Bool = false, ver: Int64 = 0, warn: Int64 = 7) -> String {
            let c = cost.map { #","lastCostFen":\#($0)"# } ?? ""
            return #"{"productId":"\#(id)","stockQty":\#(qty),"stockValueFen":\#(value)\#(c),"costKnown":\#(known),"stockVer":\#(ver),"expiryWarnDays":\#(warn)}"#
        }
        XCTAssertNoThrow(try decode(ProductPrivate.self, pp()))
        XCTAssertDecodeInvalid(ProductPrivate.self, pp(qty: 3, value: 900))                     // I3：进价未知货值必须为 0
        XCTAssertDecodeInvalid(ProductPrivate.self, pp(qty: -1, value: 0, cost: 300, known: true))
        XCTAssertDecodeInvalid(ProductPrivate.self, pp(cost: Limits.maxFen + 1))
        XCTAssertDecodeInvalid(ProductPrivate.self, pp(ver: -1))
        XCTAssertDecodeInvalid(ProductPrivate.self, pp(warn: Limits.maxExpiryWarnDays + 1))
    }

    /// 解码得到的非法单件码不可能再编码成违反契约的 barcode_link（Codex P2 第 3 条后半）
    func testDecodedRecordAlwaysEncodesSchemaValidLink() throws {
        let id = uuid(1).uuidString
        let r = try decode(BarcodeRecord.self, #"{"barcode":"16928804011118","productId":"\#(id)","packQty":24,"unitName":"箱","packPriceFen":6500}"#)
        let op = Op(id: uuid(2), occurredAt: Date(timeIntervalSince1970: 1_795_000_000), payload: BarcodeLinkPayload(r))
        XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(op.encoded())), [])
    }
}
