import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S25 商品列表（11）、改商品（22）、待确认补全（22b）、04b 进价 0 二次确认（T33）的状态与动作（不碰界面）。
@MainActor
final class S25Tests: XCTestCase {
    let beer = UUID(uuidString: "5EED0000-0000-4000-8000-000000000202")!, water = UUID(uuidString: "5EED0000-0000-4000-8000-000000000206")!,
        zhonghua = UUID(uuidString: "5EED0000-0000-4000-8000-000000000205")!

    private func makeDB(_ role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    private func payloads(_ db: LocalDB, _ type: OpType) throws -> [[String: Any]] {
        try db.pendingOps().filter { $0.type == type }.compactMap {
            (try JSONSerialization.jsonObject(with: $0.opJSON) as? [String: Any])?["payload"] as? [String: Any]
        }
    }

    /// 插一个待确认商品（`price` 0、没条码 = 卖出时服务器自动建的，§14 S05-9）
    private func addReview(_ db: LocalDB, price: Int64, stock: Int64, ver: Int64, code: String? = nil) throws -> UUID {
        let id = UUID()
        try Self.put(db, id, price: price, stock: stock, ver: ver, code: code, needsReview: true)
        return id
    }

    nonisolated static func put(_ db: LocalDB, _ id: UUID, price: Int64, stock: Int64, ver: Int64, code: String?, needsReview: Bool) throws {
        let p: [String: Any] = ["id": id.uuidString.lowercased(), "name": "白象 老母鸡汤面", "base_unit": "袋", "price_fen": price,
                                "needs_review": needsReview, "track_expiry": false, "image_ver": 0, "archived": false, "rev": 50,
                                "private": ["stock_qty": stock, "stock_value_fen": 0, "last_cost_fen": NSNull(), "cost_known": false,
                                            "stock_ver": ver, "low_at": NSNull(), "expiry_warn_days": 7, "shelf_life_months": NSNull()]
                                    as [String: Any]]
        var codes: [[String: Any]] = []
        if let code {
            codes.append(["barcode": code, "product_id": id.uuidString.lowercased(), "pack_qty": 1, "unit_name": "袋",
                          "pack_price_fen": NSNull(), "rev": 51])
        }
        let obj: [String: Any] = [
            "results": [], "changes": ["products": [p], "barcodes": codes, "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": 51, "ledger": 0], "has_more": ["catalog": false, "ledger": false], "total_products": 7,
            "server_time": "2026-11-20T10:00:00.000Z", "epoch": UUID().uuidString, "min_build": 0,
            "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店", "low_stock_default": 3]]
        try db.applySyncResponse(try SyncResponse.decode(try JSONSerialization.data(withJSONObject: obj)), sent: nil)
    }

    // MARK: 11

    func testListTextsAndFilters() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 0, ver: 1, code: "6920000000017")
        let auto = try addReview(db, price: 0, stock: -2, ver: 1)
        let m = ProductsModel(db: db)
        await m.reload(today: try CalendarDate("2026-11-20"))
        XCTAssertEqual(m.counts.all, 8)
        XCTAssertEqual(m.counts.needsReview, 2)
        XCTAssertEqual(m.counts.expiring, 3)
        XCTAssertEqual(m.counts.lowStock, 1, "待确认的不算快没货（§14 S07-6）")
        func item(_ i: UUID) throws -> ProductListItem { try XCTUnwrap(m.items.first { $0.id == i }) }
        XCTAssertEqual(m.items.prefix(2).map(\.id).sorted { $0.uuidString < $1.uuidString }, [id, auto].sorted { $0.uuidString < $1.uuidString },
                       "待确认的排在前面")
        XCTAssertEqual(ProductsModel.reviewSource(try item(id)), "收银员登记")
        XCTAssertEqual(ProductsModel.reviewSource(try item(auto)), "卖出时自动建的")
        XCTAssertNil(ProductsModel.stockLine(try item(id)), "待确认的写「进价和库存没填」")
        XCTAssertEqual(ProductsModel.stockLine(try item(beer)), "进价 ¥4.20 还剩 48 罐")
        XCTAssertEqual(ProductsModel.stockLine(try item(water)), "进价没填")
        XCTAssertEqual(ProductsModel.lowStockBadge(try item(water)), "没货了")
        XCTAssertEqual(ProductsModel.earliestText(try item(beer)), "最早一批 11-25")
        XCTAssertEqual(ProductsModel.packText(try item(beer)), "整箱码 1 箱 = 24 罐")
        XCTAssertEqual(ProductsModel.packText(try item(zhonghua)), "整条码 1 条 = 10 包")
        m.filter = .needsReview
        XCTAssertEqual(Set(m.shown.map(\.id)), [id, auto])
        m.filter = .lowStock
        XCTAssertEqual(m.shown.map(\.id), [water])
        m.filter = .all
        m.query = "6901035600023"
        XCTAssertEqual(m.shown.map(\.id), [beer], "扫整箱码也能找到")
        m.query = "可乐"
        XCTAssertEqual(m.shown.map(\.product.name), ["可口可乐 330ml"])
    }

    // MARK: 22

    func testEditSendsOnlyChangedFieldsAndUsesNewPrice() async throws {
        let db = try makeDB()
        let d = try XCTUnwrap(try db.productDetail(beer))
        let m = EditProductModel(db: db, detail: d, storeLowDefault: 3)
        XCTAssertEqual(m.averageCostText, "4.20", "平均进价只读")
        XCTAssertEqual(m.packLine(d.packs[0]), "1 箱 = 24 罐，整箱卖 ¥132.00")
        do { let ok = await m.save(); XCTAssertTrue(ok, "什么都没改：不发 op") }
        XCTAssertTrue(try db.pendingOps().isEmpty)
        m.price = YuanInput("6.5")
        m.lowAt = 6
        do { let ok = await m.save(); XCTAssertTrue(ok) }
        let p = try XCTUnwrap(try payloads(db, .productEdit).first)
        XCTAssertEqual(Set(p.keys), ["product_id", "price_fen", "low_at"])
        XCTAssertEqual(p["price_fen"] as? Int, 650)
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.unitPrice(), Fen(650), "单件码马上用新价")
        XCTAssertEqual(try db.lookup(barcode: "6901035600023")?.unitPrice(), Fen(13200), "整箱码的价不变")
    }

    func testEditZeroPriceAsksFirstAndEmptyNameRefused() async throws {
        let db = try makeDB()
        let m = EditProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(beer)), storeLowDefault: 3)
        m.price = YuanInput("0")
        do { let ok = await m.save(); XCTAssertFalse(ok) }
        XCTAssertTrue(m.confirmZeroPrice)
        XCTAssertTrue(try db.pendingOps().isEmpty)
        do { let ok = await m.save(confirmedZero: true); XCTAssertTrue(ok) }
        XCTAssertEqual(try payloads(db, .productEdit).first?["price_fen"] as? Int, 0)
        m.name = "  "
        do { let ok = await m.save(); XCTAssertFalse(ok) }
        XCTAssertEqual(m.error, "名称不能空着")
    }

    func testArchiveAndUnlinkPack() async throws {
        let db = try makeDB()
        let m = EditProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(beer)), storeLowDefault: 3)
        await m.unlink(m.detail.packs[0])
        XCTAssertTrue(m.detail.packs.isEmpty)
        XCTAssertNil(try db.lookup(barcode: "6901035600023"))
        XCTAssertEqual(try payloads(db, .barcodeUnlink).first?["barcode"] as? String, "6901035600023")
        do { let ok = await m.setArchived(true); XCTAssertTrue(ok) }
        XCTAssertEqual(try db.lookup(barcode: "6901035600016")?.product.archived, true, "停用后扫码照样认得出")
        XCTAssertEqual(try payloads(db, .productEdit).last?["archived"] as? Bool, true)
    }

    /// 管保质期、保质期月数没填：什么都不动不发；只改名称不捎上 shelf_life_months（自审建议 2）
    func testUntouchedShelfLifeNotSent() async throws {
        let db = try makeDB()
        let beerPayload = try ProductEditPayload(productId: beer, shelfLifeMonths: .set(nil))
        try db.editProduct(beerPayload)
        let m = EditProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(beer)), storeLowDefault: 3)
        XCTAssertTrue(m.trackExpiry)
        let before = try db.pendingOps().count
        do { let ok = await m.save(); XCTAssertTrue(ok) }
        XCTAssertEqual(try db.pendingOps().count, before, "什么都没改：不发")
        m.name = "青岛啤酒 经典"
        do { let ok = await m.save(); XCTAssertTrue(ok) }
        XCTAssertEqual(Set(try XCTUnwrap(try payloads(db, .productEdit).last).keys), ["product_id", "name"])
        XCTAssertNil(m.shelfMonths, "界面写「没填」")
        // 点了「没填，点这里填」：从 12 个月起，存好才发
        m.shelfMonths = EditProductModel.defaultShelfMonths
        do { let ok = await m.save(); XCTAssertTrue(ok) }
        XCTAssertEqual(try XCTUnwrap(try payloads(db, .productEdit).last)["shelf_life_months"] as? Int, 12)
    }

    /// 没设提醒线：显示店里的默认；没改就不发 low_at
    func testLowAtDefaultsToStoreDefault() async throws {
        let db = try makeDB()
        try db.editProduct(try ProductEditPayload(productId: zhonghua, lowAt: .set(nil)))
        let m = EditProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(zhonghua)), storeLowDefault: 5)
        XCTAssertEqual(m.lowAt, 5)
        m.name = "中华（软）"
        do { let ok = await m.save(); XCTAssertTrue(ok) }
        XCTAssertEqual(Set(try XCTUnwrap(try payloads(db, .productEdit).last).keys), ["product_id", "name"])
    }

    // MARK: 22b

    final class FakeBackend: @unchecked Sendable {
        var drains = 0
        var finishes = 0
        var submitted: [ProductReviewCompletePayload] = []
        var outcomes: [OnlineOutcome] = []
        var drainError: Error?
        var backend: ReviewBackend {
            ReviewBackend(drain: { [self] in drains += 1; if let e = drainError { throw e } },
                          submit: { [self] op in
                              submitted.append(op.payload as! ProductReviewCompletePayload)
                              return outcomes.isEmpty ? .applied : outcomes.removeFirst()
                          },
                          finish: { [self] in finishes += 1 })
        }
    }

    func testReviewNeedsNetworkAndCost() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 3, ver: 4, code: "6920000000017")
        let fake = FakeBackend()
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: fake.backend)
        XCTAssertEqual(m.price.text, "4.50")
        XCTAssertEqual(m.counted, 3)
        await m.confirm(offline: false)
        XCTAssertEqual(m.error, "进价要填（真是白拿的填 0）")
        m.cost = YuanInput("3.2")
        await m.confirm(offline: true)
        XCTAssertEqual(m.error, "要联网才能补全，连上网再点")
        XCTAssertEqual(fake.drains, 0, "没网一个请求都不发")
        XCTAssertTrue(fake.submitted.isEmpty)
        // 进价 0：先问
        m.cost = YuanInput("0")
        await m.confirm(offline: false)
        XCTAssertEqual(m.confirmZero, .cost)
        XCTAssertTrue(fake.submitted.isEmpty)
        m.acceptZero()
        await m.confirm(offline: false)
        XCTAssertEqual(fake.submitted.first?.unitCostFen, Fen(0), "明确为 0 照交")
        XCTAssertEqual(m.phase, .done)
        XCTAssertEqual(fake.finishes, 0, "交了：由 submit 自己让同步接着跑（被踢了不能再起），不重复")
    }

    /// 排空失败：由 drain 自己处理（被踢走 25b），不再调 finish
    func testReviewDrainFailureDoesNotFinish() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 3, ver: 4, code: "6920000000017")
        let fake = FakeBackend()
        fake.drainError = URLError(.notConnectedToInternet)
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: fake.backend)
        m.cost = YuanInput("3.2")
        await m.confirm(offline: false)
        XCTAssertEqual(m.phase, .editing)
        XCTAssertTrue(fake.submitted.isEmpty)
        XCTAssertEqual(fake.finishes, 0)
    }

    /// stale：提示账面数变了，确认后带服务器的新版本重交；排空在读基线之前
    func testReviewStaleThenConfirm() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 3, ver: 4, code: "6920000000017")
        let fake = FakeBackend()
        fake.outcomes = [.stale(stockQty: 1, stockVer: 6)]
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: fake.backend)
        m.cost = YuanInput("3.2")
        m.counted = 8
        await m.confirm(offline: false)
        XCTAssertEqual(m.phase, .stale(stockQty: 1, stockVer: 6))
        XCTAssertEqual(fake.submitted[0].baseVer, 4)
        XCTAssertEqual(fake.submitted[0].baseQty, 3)
        XCTAssertEqual(fake.submitted[0].countedQty, 8)
        XCTAssertEqual(fake.submitted[0].unitCostFen, Fen(320))
        await m.confirmStale()
        XCTAssertEqual(fake.submitted[1].baseVer, 6)
        XCTAssertEqual(fake.submitted[1].baseQty, 1)
        XCTAssertNotEqual(fake.submitted[0].entryId, fake.submitted[1].entryId)
        XCTAssertEqual(m.phase, .done)
    }

    /// §14 S05-9：自动建的（卖价 0、没条码）先让人填卖价；卖价和挂码排进 outbox（排空时先传），不发 product_upsert
    func testAutoCreatedReviewQueuesEditAndLinkFirst() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 0, stock: -2, ver: 1)
        let fake = FakeBackend()
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: fake.backend)
        XCTAssertTrue(m.price.isEmpty, "卖价 0 的框留空，先让人填")
        XCTAssertTrue(m.needsBarcode)
        m.cost = YuanInput("3.2")
        await m.confirm(offline: false)
        XCTAssertEqual(m.error, "先填卖多少钱")
        m.price = YuanInput("4.5")
        m.barcode = "6920000000017"
        await m.confirm(offline: false)
        XCTAssertEqual(try payloads(db, .productEdit).first?["price_fen"] as? Int, 450)
        let link = try XCTUnwrap(try payloads(db, .barcodeLink).first)
        XCTAssertEqual(link["pack_qty"] as? Int, 1)
        XCTAssertNil(link["pack_price_fen"], "单件码不带价")
        XCTAssertTrue(try payloads(db, .productUpsert).isEmpty)
        XCTAssertEqual(fake.drains, 1, "排空（把这两条传上去）在交补全之前")
        XCTAssertEqual(fake.submitted.count, 1)
    }

    /// 上一次其实交上去了（或者别的手机先补全了）：排空拉下来已经不是待确认，不交第二次
    func testReviewNotResubmittedWhenAlreadyCompleted() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 3, ver: 4, code: "6920000000017")
        let fake = FakeBackend()
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: ReviewBackend(
            drain: { fake.drains += 1; try Self.clearReview(db, id) },
            submit: fake.backend.submit, finish: fake.backend.finish))
        m.cost = YuanInput("3.2")
        await m.confirm(offline: false)
        XCTAssertEqual(m.phase, .done)
        XCTAssertTrue(fake.submitted.isEmpty)
        XCTAssertEqual(fake.finishes, 1, "排空成功但没交：定时同步也要接着跑（自审建议 1）")
    }

    nonisolated static func clearReview(_ db: LocalDB, _ id: UUID) throws {
        try put(db, id, price: 450, stock: 8, ver: 5, code: nil, needsReview: false)
    }

    func testReviewNetworkErrorKeepsEditing() async throws {
        let db = try makeDB()
        let id = try addReview(db, price: 450, stock: 3, ver: 4, code: "6920000000017")
        let fake = FakeBackend()
        fake.drainError = URLError(.notConnectedToInternet)
        let m = ReviewProductModel(db: db, detail: try XCTUnwrap(try db.productDetail(id)), backend: fake.backend)
        m.cost = YuanInput("3.2")
        await m.confirm(offline: false)
        XCTAssertEqual(m.phase, .editing)
        XCTAssertEqual(m.error, "没连上，没补全。连上网再点一次")
        fake.drainError = OnlineSubmitError.outboxNotDrained(2)
        await m.confirm(offline: false)
        XCTAssertEqual(m.error, "还有账没传上去，等传完再补全（看看网）")
        XCTAssertTrue(fake.submitted.isEmpty)
    }

    // MARK: T33

    /// 04b 进价填 0 直接存：和进货页一样先问；没填（空）不问，记成进价未知
    func testNewProductZeroCostAsksFirst() throws {
        let db = try makeDB()
        let m = NewProductModel(db: db, barcode: "6920000000099", mode: .sell, quick: false, canLinkPack: true)
        m.name = "新东西"
        m.price = YuanInput("5")
        m.goMore()
        m.qtyText = "10"
        m.cost = YuanInput("0")
        XCTAssertNil(m.saveMore())
        XCTAssertTrue(m.confirmZeroCost)
        XCTAssertNil(try db.lookup(barcode: "6920000000099"), "没确认什么都不写")
        XCTAssertNotNil(m.saveMore(confirmedZero: true, confirmedZeroCost: true))
        let o = try XCTUnwrap(try payloads(db, .opening).first)
        XCTAssertEqual(o["unit_cost_fen"] as? Int, 0, "明确为 0")

        let db2 = try makeDB()
        let n = NewProductModel(db: db2, barcode: "6920000000098", mode: .sell, quick: false, canLinkPack: true)
        n.name = "新东西"; n.price = YuanInput("5"); n.goMore(); n.qtyText = "10"
        XCTAssertNotNil(n.saveMore(), "没填进价不问")
        XCTAssertFalse(n.confirmZeroCost)
        XCTAssertNil(try XCTUnwrap(try payloads(db2, .opening).first)["unit_cost_fen"], "没填 = 进价未知，不带这个键")
    }
}
