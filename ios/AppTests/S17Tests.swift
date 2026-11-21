import ShopCore
import UIKit
import XCTest
@testable import YuanhuiZhangben

/// S17：抹零面板（18 / 28）、手输条码（15 / 15b）的模型，以及抹零经卖出页记账后各行实收与契约向量逐分一致。
@MainActor
final class S17Tests: XCTestCase {
    static let beer = "6901035600016", erguotou = "6901234500011", noodle = "6902514300011", noodle2 = "6902514300035"

    private func makeDB(role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    private func designModel() throws -> SellModel {
        let m = SellModel(db: try makeDB())
        for c in [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle] {
            XCTAssertEqual(m.handle(Scan(code: c, source: .gun)), .known)
        }
        XCTAssertEqual(m.listTotalFen, 5350)
        return m
    }

    private func press(_ d: DiscountModel, _ s: String) {
        for ch in s { d.key(ch == "." ? .dot : .digit(Int(String(ch))!)) }
    }

    // MARK: 验收：¥53.50 抹到 ¥53 → 24.76 / 23.78 / 4.46

    func testRoundToYuanGivesDesignAllocationAndRecordsIt() throws {
        let m = try designModel()
        let d = DiscountModel(basket: m.basket)
        XCTAssertEqual(d.roundYuanFen, 5300)
        XCTAssertEqual(d.roundTenFen, 5000)
        d.round(to: d.roundYuanFen)
        XCTAssertEqual(d.text, "53")
        XCTAssertTrue(d.isSelected(5300), "「抹到 ¥53」亮")
        XCTAssertEqual(d.discountFen, 50, "优惠 ¥0.50")
        let r = try XCTUnwrap(d.submit(), "53/53.50 在七折以上，不再问")
        XCTAssertEqual(r, .paid(5300))
        m.applyDiscount(r)
        XCTAssertEqual(m.paidTotalFen, 5300)
        XCTAssertEqual(m.discountFen, 50)
        let byName = Dictionary(uniqueKeysWithValues: try m.basket.allocation().amountFen.enumerated().map {
            (m.basket.lines[$0.offset].barcode, $0.element) })
        XCTAssertEqual(byName[Self.erguotou], 2476)
        XCTAssertEqual(byName[Self.beer], 2378)
        XCTAssertEqual(byName[Self.noodle], 446)
        XCTAssertTrue(m.commit())
        let sales = try m.db.entries().filter { $0.type == .sale }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sales.map { ($0.name, $0.amountFen.raw) }),
                       ["牛栏山二锅头 500ml": 2476, "青岛啤酒 500ml": 2378, "康师傅红烧牛肉面": 446], "记进本地库的各行实收")
    }

    /// 契约 `allocation.json` 每一组：按件数和换算数量（`pack_qty`，缺省 1）装进卖出页购物篮 → 在面板上按出实收
    /// （要问的点「没错」）→ 记账，本地库里各行实收与向量逐分一致。
    /// 向量里该拒的组（`expect.error`），每一组都要在店里人能走到的某一步被拒（装篮超上限、全零篮改价按钮灰、
    /// 面板超实收上限不让定、负数按不出来），不许静默跳过；能记的组装篮或面板失败也算错。最后按 id 核对每组都有归属。
    func testEveryAllocationVectorThroughPanelAndCommitMatchesToTheFen() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../contracts/vectors/allocation.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        var recorded: [String] = [], rejected: [String: String] = [:]
        for c in cases {
            let id = c["id"] as! String
            let raw = c["lines"] as! [[String: Any]]
            let prices = raw.map { ($0["unit_price_fen"] as! NSNumber).int64Value }
            let counts = raw.map { ($0["pack_count"] as! NSNumber).int64Value }
            let packQtys = raw.map { ($0["pack_qty"] as? NSNumber)?.int64Value ?? 1 }
            let paid = (c["paid_total_fen"] as! NSNumber).int64Value
            let expect = ((c["expect"] as? [String: Any])?["amount_fen"] as? [NSNumber])?.map(\.int64Value)  // nil = 这一组该被拒
            XCTAssertTrue(expect != nil || (c["expect"] as? [String: Any])?["error"] as? String == "invalid", "\(id)：要么有结果，要么该拒")

            let db = try makeDB()
            var products: [Product] = [], codes: [BarcodeRecord] = []
            for (i, price) in prices.enumerated() {
                let q = packQtys[i]
                // 向量的 unit_price_fen 是一件（一个包装）的卖价；整件码用 packPriceFen 写死这一件的价
                let p = try Product(id: UUID(), name: "向量\(id)-\(i)", baseUnit: "个", priceFen: Fen(q > 1 ? 0 : price))
                products.append(p)
                codes.append(try BarcodeRecord(barcode: String(format: "17%011d", i), productId: p.id, packQty: q,
                                               unitName: q > 1 ? "箱" : "个", packPriceFen: q > 1 ? Fen(price) : nil))
            }
            try db.applyBaseline(CatalogBaseline(products: products, barcodes: codes))
            let m = SellModel(db: db)
            // 1. 装篮：一样一样扫进来、改件数；超 §5.0 上限的这一步被拒
            var buildFailure: String?
            for (i, n) in counts.enumerated() {
                guard m.handle(Scan(code: codes[i].barcode, source: .gun)) == .known else { buildFailure = "第 \(i + 1) 样扫不进"; break }
                XCTAssertEqual(m.basket.lines[i].packQty, packQtys[i], "\(id)：换算数量")
                if n != 1 { m.setCount(lineId: m.basket.lines[i].id, Int(n)) }
                if m.count(lineId: m.basket.lines[i].id) != n { buildFailure = "第 \(i + 1) 样改不到 \(n) 件"; break }
            }
            if let buildFailure {
                if expect == nil { rejected[id] = "装篮：" + buildFailure } else { XCTFail("\(id)：该能记的组装篮失败（\(buildFailure)）") }
                continue
            }
            // 2. 面板：按出实收
            if paid < 0 {
                // 面板没有负号键，负数按不出来；绕过面板直接交也被 ShopCore 拒
                XCTAssertNil(DiscountModel.parseFen("-0.01"), id)
                XCTAssertThrowsError(try m.setPaid(paid), id)
                XCTAssertNil(expect, "\(id)：负实收不该有结果")
                rejected[id] = "负实收"
                continue
            }
            if m.listTotalFen == 0 {
                XCTAssertFalse(m.canChangePaid, "\(id)：全零购物篮改价按钮不可用")
                if paid != 0 {
                    XCTAssertNil(expect, "\(id)：全零篮改价该拒")
                    rejected[id] = "全零篮改价按钮灰"
                    continue
                }
            } else {
                let d = DiscountModel(basket: m.basket)
                press(d, DiscountModel.yuanText(paid))
                guard d.canSubmit else {
                    if expect == nil { rejected[id] = "面板不让定：\(d.limitMessage ?? "")" } else { XCTFail("\(id)：该能记的组面板不让定") }
                    continue
                }
                var r = d.submit()
                if r == nil { r = d.confirm() }
                guard let r else { XCTFail("\(id)：面板定不下来"); continue }
                m.applyDiscount(r)
            }
            // 3. 记账，逐分核对
            guard let expect else { XCTFail("\(id)：该拒的组一路走到了记账"); continue }
            XCTAssertEqual(m.paidTotalFen, paid, id)
            XCTAssertTrue(m.commit(), id)
            let sales = try db.entries(limit: 1000).filter { $0.type == .sale }
            let byName = Dictionary(uniqueKeysWithValues: sales.map { ($0.name, $0.amountFen.raw) })
            XCTAssertEqual(prices.indices.map { byName["向量\(id)-\($0)"] ?? -1 }, expect, "\(id) 逐分")
            recorded.append(id)
        }
        let all = Set(cases.map { $0["id"] as! String })
        XCTAssertEqual(Set(recorded).union(rejected.keys), all, "每一组都有归属：记过或明确被拒")
        XCTAssertTrue(Set(recorded).isDisjoint(with: rejected.keys))
        XCTAssertEqual(recorded.count + rejected.count, cases.count)
        // 已知该拒的组都要在这里被拒到（契约加组时这里一起改）
        XCTAssertEqual(Set(rejected.keys), ["alloc-13", "alloc-20", "alloc-21", "alloc-22", "alloc-23", "alloc-26", "alloc-28"],
                       "被拒的组：\(rejected)")
        XCTAssertTrue(recorded.contains("alloc-27"), "pack_qty 9999 × 1000 件 = 9999000 基本单位，恰在上限内能记")
    }

    // MARK: 28：低于七折 / 多收

    func testBelowSeventyPercentAsksWithRefillAndConfirm() throws {
        let m = try designModel()
        let d = DiscountModel(basket: m.basket)
        press(d, "5")
        XCTAssertNil(d.submit(), "5 / 53.50 不到七折，先问")
        XCTAssertEqual(d.stage, .confirm(paidFen: 500, over: false))
        XCTAssertEqual(d.confirmTitle(paidFen: 500, over: false), "原价 ¥53.50，\n只收 ¥5.00？")
        XCTAssertEqual(d.confirmDetail(paidFen: 500, over: false), "比原价少了一大半，是不是少按了一位？")
        d.refill()
        XCTAssertEqual(d.stage, .input)
        XCTAssertEqual(d.text, "", "重填清掉")
        press(d, "5")
        _ = d.submit()
        XCTAssertEqual(d.confirm(), .paid(500), "没错，就收 ¥5.00")
        // 七折边上：37.45 = 恰好七折，不问；37.44 问
        let e = DiscountModel(basket: m.basket)
        press(e, "37.45")
        XCTAssertEqual(e.submit(), .paid(3745))
        let f = DiscountModel(basket: m.basket)
        press(f, "37.44")
        XCTAssertNil(f.submit())
        XCTAssertEqual(f.confirmDetail(paidFen: 3744, over: false), "比原价少了 ¥16.06，不到七折，是不是按错了？")
    }

    func testOverchargeAsksWithTheOtherWording() throws {
        let m = try designModel()
        let d = DiscountModel(basket: m.basket)
        press(d, "535")
        XCTAssertNil(d.submit())
        XCTAssertEqual(d.stage, .confirm(paidFen: 53500, over: true))
        XCTAssertEqual(d.confirmTitle(paidFen: 53500, over: true), "原价 ¥53.50，\n要收 ¥535.00？")
        XCTAssertEqual(d.confirmDetail(paidFen: 53500, over: true), "比原价多收了 ¥481.50，是不是多按了一位？")
        XCTAssertEqual(d.discountFen, -48150, "多收为负，面板上写「多收」")
    }

    // MARK: 不抹了、全零、输入限制

    func testRestoreGoesBackToListPrice() throws {
        let m = try designModel()
        m.applyDiscount(.paid(5300))
        XCTAssertEqual(DiscountModel(basket: m.basket).text, "53", "再打开面板带着上次的实收")
        m.applyDiscount(.restore)
        XCTAssertNil(m.discountFen)
        XCTAssertEqual(m.paidTotalFen, 5350)
        let d = DiscountModel(basket: m.basket)
        press(d, "53.50")
        XCTAssertEqual(d.submit(), .restore, "输的正好是原价 = 不抹")
    }

    func testAllZeroPriceBasketCannotChangePaid() throws {
        let db = try makeDB()
        let p = try Product(id: UUID(), name: "购物袋", baseUnit: "个", priceFen: .zero)
        try db.applyBaseline(CatalogBaseline(products: [p], barcodes: [
            try BarcodeRecord(barcode: "6900000000024", productId: p.id, packQty: 1, unitName: "个", packPriceFen: nil)]))
        let m = SellModel(db: db)
        XCTAssertEqual(m.handle(Scan(code: "6900000000024", source: .gun)), .known)
        XCTAssertFalse(m.canChangePaid)
        XCTAssertTrue(m.canCommit)
    }

    func testKeypadInputRules() {
        XCTAssertEqual(DiscountModel.parseFen("53"), 5300)
        XCTAssertEqual(DiscountModel.parseFen("53.5"), 5350)
        XCTAssertEqual(DiscountModel.parseFen("0.05"), 5)
        XCTAssertEqual(DiscountModel.parseFen(".5"), 50)
        XCTAssertNil(DiscountModel.parseFen("."))
        XCTAssertNil(DiscountModel.parseFen(""))
        XCTAssertEqual(DiscountModel.yuanText(5300), "53")
        XCTAssertEqual(DiscountModel.yuanText(5350), "53.50")
        let b = Basket()
        let d = DiscountModel(basket: b)
        for k in [Keypad.Key.digit(0), .digit(0), .digit(7)] { d.key(k) }
        XCTAssertEqual(d.text, "7", "前导 0 不留")
        d.key(.dot); d.key(.dot); d.key(.digit(1)); d.key(.digit(2)); d.key(.digit(3))
        XCTAssertEqual(d.text, "7.12", "一个小数点、最多两位小数")
        let e = DiscountModel(basket: b)
        for _ in 0..<12 { e.key(.digit(9)) }
        XCTAssertEqual(e.text.count, DiscountModel.maxIntegerDigits, "整数最多 9 位")
        XCTAssertEqual(e.limitMessage, "一笔最多收 ¥199999998.00", "超上限说店里人的话（§14 S16-6），不显示内部原因")
        XCTAssertFalse(e.canSubmit)
    }

    // MARK: 15 / 15b 手输条码、按名称找

    private func addSameMaker(_ db: LocalDB) throws {
        let p = try Product(id: UUID(), name: "康师傅老坛酸菜牛肉面", baseUnit: "桶", priceFen: Fen(450))
        try db.applyBaseline(CatalogBaseline(products: [p], barcodes: [
            try BarcodeRecord(barcode: "6902514300028", productId: p.id, packQty: 1, unitName: "桶", packPriceFen: nil)]))
    }

    func testPrefixWithTwoHitsListsBothAndDoesNotAutoSelect() throws {
        let db = try makeDB()
        try addSameMaker(db)
        let m = ManualCodeModel(db: db)
        m.type("6902514")
        XCTAssertTrue(m.candidates.isEmpty, "不满 8 位不列")
        XCTAssertEqual(m.codeHint, "输满 8 位就列出来，点对的那个")
        m.key(.digit(3))
        XCTAssertEqual(m.candidates.map(\.representativeBarcode), ["6902514300011", "6902514300028"],
                       "同前缀两个商品都列；红烧牛肉面两个单件码只算一个")
        XCTAssertFalse(m.canPick, "两个时不自动选，主按钮灰")
        XCTAssertNil(m.pick())
        m.select(m.candidates[1].conversion)
        XCTAssertEqual(m.pick(), "6902514300028", "点一行后可加入")
        m.type("00028")
        XCTAssertEqual(m.candidates.count, 1)
        XCTAssertTrue(m.canPick, "只剩一个才自动选中")
    }

    func testPickedCodeGoesThroughTheHubIntoTheBasket() throws {
        let db = try makeDB()
        try addSameMaker(db)
        let sell = SellModel(db: db)
        let hub = ScanHub()
        hub.handler = { sell.handle($0) }
        let m = ManualCodeModel(db: db)
        m.type("69025143")
        m.select(m.candidates[1].conversion)
        XCTAssertEqual(hub.receive(try XCTUnwrap(m.pick()), from: .manual), .known)
        XCTAssertEqual(sell.basket.lines.map(\.name), ["康师傅老坛酸菜牛肉面"])
    }

    /// §14 S14-5：手输的码含数字、字母以外的字符不收，提示「条码只能是数字和字母」；字母大小写原样
    func testManualInputRejectsOtherCharacters() throws {
        let m = ManualCodeModel(db: try makeDB())
        m.type("6901-035")
        XCTAssertEqual(m.input, "", "整串不收、不截断")
        XCTAssertEqual(m.codeHint, "条码只能是数字和字母")
        XCTAssertNil(m.hardwareKey(.character("#")))
        XCTAssertEqual(m.codeHint, "条码只能是数字和字母")
        XCTAssertNil(m.hardwareKey(.enter))
        XCTAssertEqual(m.codeHint, "条码只能是数字和字母", "提示留到下一串开始")
        _ = m.hardwareKey(.character("A")); _ = m.hardwareKey(.character("b"))
        XCTAssertEqual(m.input, "Ab", "大小写原样")
        _ = m.hardwareKey(.character("\u{8}"))
        XCTAssertEqual(m.input, "A")
    }

    /// 手输页上用扫码枪 / 硬件键盘「打」一串码进来，回车交出（交出的码像页面一样走 ScanHub 进篮）
    @discardableResult
    private func gunType(_ m: ManualCodeModel, _ keys: [HIDScanParser.Key], into sell: SellModel) -> String? {
        let hub = ScanHub()
        hub.handler = { sell.handle($0) }
        var out: String?
        for k in keys {
            if let code = m.hardwareKey(k) { out = code; _ = hub.receive(code, from: .manual) }
        }
        return out
    }

    private func keys(_ s: String) -> [HIDScanParser.Key] { s.map { .character($0) } }

    /// §14 S14-5：手输页上一次扫码（到回车为止）里出现任何非法字符或非法键，整串不收、不截断：
    /// 不交码、不选中、不进篮，提示「条码只能是数字和字母」（`6901-035600016` 不能变成啤酒码 `6901035600016`）
    func testHardwareStringWithIllegalCharacterIsDroppedWhole() throws {
        let cases: [(String, [HIDScanParser.Key])] = [
            ("开头", keys("-6901035600016")),
            ("中间", keys("6901-035600016")),
            ("末尾", keys("6901035600016-")),
            ("中间空格", keys("690103 5600016")),
            ("非法键", keys("6901") + [.other] + keys("035600016")),
            ("非法键在末尾", keys("6901035600016") + [.other]),
        ]
        for (name, ks) in cases {
            let db = try makeDB()
            let sell = SellModel(db: db)
            let m = ManualCodeModel(db: db)
            XCTAssertNil(gunType(m, ks + [.enter], into: sell), "\(name)：回车不交码")
            XCTAssertTrue(sell.basket.lines.isEmpty, "\(name)：篮子不变")
            XCTAssertNil(m.selected, "\(name)：不选中")
            XCTAssertFalse(m.canPick, "\(name)：主按钮灰")
            XCTAssertNotEqual(m.input, Self.beer, "\(name)：不截掉符号拼成另一个码")
            XCTAssertEqual(m.codeHint, ManualCodeModel.invalidCharacterHint, "\(name)：提示")
            XCTAssertNil(m.pick(), "\(name)：主按钮也交不出")
            XCTAssertTrue(try db.entries().isEmpty, "\(name)：不写账")
            // 作废的一串结束后，下一枪正常收
            XCTAssertEqual(gunType(m, keys(Self.beer) + [.enter], into: sell), Self.beer, "\(name)：下一枪照收")
            XCTAssertEqual(sell.basket.lines.map(\.barcode), [Self.beer], "\(name)：下一枪进篮")
        }
    }

    /// 作废后、回车之前，后面的字符也不拼进去（前缀唯一命中时也不自动选）
    func testHardwareCharactersAfterIllegalOneAreNotAppended() throws {
        let m = ManualCodeModel(db: try makeDB())
        for k in keys("ab#") + keys("69010356") { XCTAssertNil(m.hardwareKey(k)) }
        XCTAssertEqual(m.input, "", "整串丢掉")
        XCTAssertTrue(m.candidates.isEmpty)
        XCTAssertNil(m.selected)
        XCTAssertEqual(m.codeHint, ManualCodeModel.invalidCharacterHint)
        m.key(.digit(6))
        XCTAssertEqual(m.input, "6", "自家键盘按一下 = 明确重填")
    }

    /// 扫码枪连着时（软键盘不弹）手输条码照样能用：扫码枪在手输页上扫，码进输入框；只有一个候选时回车直接交出去
    func testGunOnManualPageFillsTheFieldAndEnterPicks() throws {
        let m = ManualCodeModel(db: try makeDB())
        for c in Self.beer { XCTAssertNil(m.hardwareKey(.character(c))) }
        XCTAssertEqual(m.hardwareKey(.enter), Self.beer)
    }

    /// 扫到本机没有的码：回车后清掉输入框（下一枪不接在后面），提示「本机没有这个码」
    func testEnterOnUnlistedCodeClearsTheField() throws {
        let sell = SellModel(db: try makeDB())
        let m = ManualCodeModel(db: sell.db)
        XCTAssertNil(gunType(m, keys("6999999999994") + [.enter], into: sell))
        XCTAssertEqual(m.input, "")
        XCTAssertEqual(m.codeHint, "本机没有这个码")
        XCTAssertEqual(gunType(m, keys(Self.beer) + [.enter], into: sell), Self.beer, "下一枪不接在后面")
        XCTAssertEqual(sell.basket.lines.map(\.barcode), [Self.beer])
    }

    func testNameSearchHasNoStockWordsForCashier() throws {
        let m = ManualCodeModel(db: try makeDB(role: .cashier))
        m.tab = .name
        m.query = "康师傅"
        XCTAssertEqual(m.nameResults.map(\.product.name), ["康师傅红烧牛肉面"], "两个单件码只出一行")
        XCTAssertFalse(m.canPick, "按名称找不自动选")
        m.select(m.nameResults[0])
        XCTAssertNotNil(m.pick())
    }

    // MARK: §14 S14-4：关面板时主动抢回扫码枪

    func testCaptureViewReclaimsFirstResponderWhenReactivatedWithoutKeyboardNotification() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        let v = HIDKeyCaptureView(frame: .zero)
        vc.view.addSubview(v)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(v.isFirstResponder)
        v.isActive = false
        XCTAssertFalse(v.isFirstResponder, "面板盖着时让出")
        v.isActive = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(v.isFirstResponder, "面板一关就抢回，不等键盘收起的通知")
    }

    // MARK: §14 S16-1：作废黄条

    func testPaidClearedNoticeIsShownLonger() throws {
        let m = try designModel()
        m.applyDiscount(.paid(5300))
        _ = m.handle(Scan(code: Self.noodle, source: .gun))
        XCTAssertEqual(m.notice, .paidCleared)
        XCTAssertEqual(m.notice?.seconds, 8)
        XCTAssertEqual(SellModel.Notice.unknownBarcode("1").seconds, 4)
        _ = m.handle(Scan(code: "0000000000000", source: .gun))
        XCTAssertEqual(m.paidTotalFen, m.listTotalFen, "被拒的扫码不算篮子变了")
    }
}
