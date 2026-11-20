/// §5.0 的输入上限（规则，服务器同样校验，超出拒 `invalid`）。
public enum Limits {
    /// 单价、进货每件单价、单行金额（单价 × 件数；进货总价）≤ 99,999,999 分
    public static let maxFen: Int64 = 99_999_999
    /// 一笔卖出的实收 ≤ 19,999,999,800 分（200 行 × 单行上限，多收也不能超过）
    public static let maxPaidTotalFen: Int64 = 19_999_999_800
    /// 件数 pack_count ≤ 99,999
    public static let maxPackCount: Int64 = 99_999
    /// 换算 pack_qty：1 … 9,999
    public static let maxPackQty: Int64 = 9_999
    /// 基本单位数量（件数 × 换算、盘点数、期初数、实际数等）≤ 9,999,999；base_qty 绝对值同此
    public static let maxBaseQty: Int64 = 9_999_999
    /// 一笔卖出最多 200 行
    public static let maxSaleLines = 200
    /// 条码、名称、单位名的长度（ops.schema.json）
    public static let maxBarcodeLength = 64
    public static let maxNameLength = 200
    public static let maxUnitLength = 20
    /// low_at（ops.schema.json）
    public static let maxLowAt: Int64 = 99_999
    /// expiry_warn_days 0…3650，shelf_life_months 1…1200，lot_snooze days 1…365（ops.schema.json）
    public static let maxExpiryWarnDays: Int64 = 3_650
    public static let maxShelfLifeMonths: Int64 = 1_200
    public static let maxSnoozeDays: Int64 = 365

    // MARK: - 校验（失败抛 ShopCoreError.invalid）

    public static func checkFen(_ v: Int64, _ what: String) throws {
        guard v >= 0, v <= maxFen else { throw invalid("\(what) 超出 0…\(maxFen)：\(v)") }
    }

    public static func checkPackCount(_ v: Int64) throws {
        guard v >= 0, v <= maxPackCount else { throw invalid("件数超出 0…\(maxPackCount)：\(v)") }
    }

    public static func checkPackQty(_ v: Int64) throws {
        guard v >= 1, v <= maxPackQty else { throw invalid("换算数量超出 1…\(maxPackQty)：\(v)") }
    }

    public static func checkQty(_ v: Int64, _ what: String) throws {
        guard v >= 0, v <= maxBaseQty else { throw invalid("\(what) 超出 0…\(maxBaseQty)：\(v)") }
    }

    public static func checkBaseQty(_ v: Int64) throws {
        guard v >= -maxBaseQty, v <= maxBaseQty else { throw invalid("账面数超出 ±\(maxBaseQty)：\(v)") }
    }

    public static func checkPaidTotal(_ v: Int64) throws {
        guard v >= 0, v <= maxPaidTotalFen else { throw invalid("实收超出 0…\(maxPaidTotalFen)：\(v)") }
    }

    /// 件数 × 换算 = 基本单位数量，≤ 9,999,999
    @discardableResult
    public static func baseQty(packQty: Int64, packCount: Int64) throws -> Int64 {
        try checkPackQty(packQty)
        try checkPackCount(packCount)
        let n = try Checked.mul(packQty, packCount)
        try checkQty(n, "基本单位数量")
        return n
    }

    /// 单价 × 件数 = 单行金额（进货是件数 × 每件单价 = 进货总价），≤ 99,999,999
    @discardableResult
    public static func lineAmount(unitFen: Int64, packCount: Int64) throws -> Int64 {
        try checkFen(unitFen, "单价")
        try checkPackCount(packCount)
        let a = try Checked.mul(unitFen, packCount)
        try checkFen(a, "单行金额")
        return a
    }

    static func checkText(_ s: String, max: Int, _ what: String) throws {
        // JSON Schema 的 minLength/maxLength 按 Unicode 码点数
        let n = s.unicodeScalars.count
        guard n >= 1, n <= max else { throw invalid("\(what) 长度要在 1…\(max)：\(n)") }
    }
}
