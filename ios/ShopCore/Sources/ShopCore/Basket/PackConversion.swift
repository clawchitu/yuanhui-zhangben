/// 扫到一个码之后「卖 / 进 1 件是几个基本单位、多少钱」（§3.2、§5.2「整件卖」）。
public struct PackConversion: Hashable, Sendable {
    public let product: Product
    public let barcode: BarcodeRecord

    public init(product: Product, barcode: BarcodeRecord) throws {
        guard barcode.productId == product.id else { throw invalid("条码不属于这个商品") }
        self.product = product
        self.barcode = barcode
    }

    /// 1 件 = 几个基本单位
    public var packQty: Int64 { barcode.packQty }

    /// 1 件的卖价：单件码读商品卖价；整件码读自己的价，没设价时按「单件卖价 × 换算数量」（§14 S02-5）。
    public func unitPrice() throws -> Fen {
        guard barcode.isPack else { return product.priceFen }
        if let p = barcode.packPriceFen { return p }
        let v = try Checked.mul(product.priceFen.raw, barcode.packQty)
        try Limits.checkFen(v, "整件卖价")
        return Fen(v)
    }

    /// `packCount` 件换算成基本单位（5 箱 × 24 = 120 罐），带 §5.0 上限校验。
    public func baseQty(packCount: Int64) throws -> Int64 {
        try Limits.baseQty(packQty: barcode.packQty, packCount: packCount)
    }

    /// 行上显示的单位：「罐」或「箱（24 罐）」（§5.5）
    public var unitLabel: String {
        barcode.isPack ? "\(barcode.unitName)（\(barcode.packQty) \(product.baseUnit)）" : barcode.unitName
    }
}
