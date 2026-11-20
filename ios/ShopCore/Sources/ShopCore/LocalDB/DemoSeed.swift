import Foundation

/// 演示用种子数据（C 阶段没有服务器时装到手机上给人看；`-uiFixture` 也用它）。
/// 设计稿 03 的三样（合计 ¥53.50）+ 整箱可乐、整条香烟、两个单件码的方便面。
/// 收银员会话下只写商品和条码，不写进价、库存、批次。
public enum DemoSeed {
    static func id(_ n: Int) -> UUID {
        let hex = String(n, radix: 16)
        return UUID(uuidString: "5EED0000-0000-4000-8000-" + String(repeating: "0", count: 12 - hex.count) + hex)!
    }

    public static let storeId = id(0x1)

    public static func baseline(includePrivate: Bool) throws -> CatalogBaseline {
        struct Item { let n: Int; let name: String; let unit: String; let price: Int64; let codes: [(String, Int64, String, Int64?)]
                      let stock: Int64; let cost: Int64?; let expiry: Bool }
        let items: [Item] = [
            Item(n: 0x201, name: "牛栏山二锅头 500ml", unit: "瓶", price: 2500, codes: [("6901234500011", 1, "瓶", nil)], stock: 12, cost: 1800, expiry: false),
            Item(n: 0x202, name: "青岛啤酒 500ml", unit: "罐", price: 600, codes: [("6901035600016", 1, "罐", nil), ("6901035600023", 24, "箱", 13200)],
                 stock: 48, cost: 420, expiry: true),
            Item(n: 0x203, name: "康师傅红烧牛肉面", unit: "桶", price: 450, codes: [("6902514300011", 1, "桶", nil), ("6902514300035", 1, "桶", nil)],
                 stock: 20, cost: 300, expiry: true),
            Item(n: 0x204, name: "可口可乐 330ml", unit: "罐", price: 300, codes: [("6925303770013", 1, "罐", nil), ("6925303770020", 24, "箱", nil)],
                 stock: 30, cost: 200, expiry: true),
            Item(n: 0x205, name: "中华（硬）", unit: "包", price: 4500, codes: [("6901028075862", 1, "包", nil), ("6901028075879", 10, "条", 45000)],
                 stock: 6, cost: 4000, expiry: false),
            Item(n: 0x206, name: "农夫山泉 550ml", unit: "瓶", price: 200, codes: [("6921168509256", 1, "瓶", nil)], stock: -2, cost: nil, expiry: false),
        ]
        var b = CatalogBaseline()
        for it in items {
            let p = try Product(id: id(it.n), name: it.name, baseUnit: it.unit, priceFen: Fen(it.price), trackExpiry: it.expiry)
            b.products.append(p)
            for (code, qty, unitName, packPrice) in it.codes {
                b.barcodes.append(try BarcodeRecord(barcode: code, productId: p.id, packQty: qty, unitName: unitName,
                                                    packPriceFen: packPrice.map(Fen.init)))
            }
            guard includePrivate else { continue }
            let known = it.cost != nil
            let value: Int64 = known ? try Checked.mul(it.stock, it.cost!) : 0
            b.privates.append(try ProductPrivate(productId: p.id, stockQty: it.stock, stockValueFen: Fen(value),
                                                 lastCostFen: it.cost.map(Fen.init), costKnown: known, stockVer: 1, lowAt: 3,
                                                 shelfLifeMonths: it.expiry ? 12 : nil))
            if it.expiry {
                b.lots.append(try LocalLot(id: id(it.n + 0x100), productId: p.id, expiryDate: try CalendarDate("2026-11-25"),
                                           qtyIn: it.stock, qtyLeft: it.stock))
            }
        }
        return b
    }

    /// 给当前会话装上演示数据（收银员会话自动不带私有数据）
    public static func install(into db: LocalDB) throws {
        guard let s = try db.currentSession() else { throw invalid("先开会话再装演示数据") }
        try db.applyBaseline(try baseline(includePrivate: s.holdsPrivateData))
    }
}
