import Foundation

/// 进货页（06a）蓝卡上的数：一共多少钱、入账多少基本单位、这批的单位成本、临时库存，
/// 以及「加上原来的，平均进价」这个**仅供显示的预计值**（S19 说明）。
///
/// - 一共 `T = 件数 × 每件单价`，入账 `n = 件数 × 换算`，这批单位成本 `b = roundDiv(T, n)`（§5.2），
///   全部是整数分，乘法带溢出检查和 §5.0 上限（和 `StockInPayload` 同一套）。
/// - 预计平均 = `roundDiv(本地基线货值 + T, 进货后的临时库存)`；进价未知（`k` 为假）或进货前的临时库存不为正时没有（不显示）。
///   不写入任何流水；权威的平均进价由服务器算（S22a、S28 对账）。
public struct StockInPreview: Hashable, Sendable {
    public let totalFen: Fen
    public let baseQty: Int64
    public let batchUnitCostFen: Fen
    /// 进货后的临时库存（基线 + 未确认 op + 这批）；收银员手机没有基线时是 nil
    public let newStockQty: Int64?
    /// 预计平均进价；不显示时是 nil
    public let averageCostFen: Fen?

    /// - Parameters:
    ///   - baseline: 本地基线（`product_private`，只由拉取更新）
    ///   - stockBefore: 进货前的临时库存（`DisplayStock.qty`）
    public init(packQty: Int64, packCount: Int64, unitCostFen: Fen, baseline: ProductPrivate?, stockBefore: Int64?) throws {
        guard packCount >= 1 else { throw invalid("进货件数至少 1：\(packCount)") }
        try Limits.checkFen(unitCostFen.raw, "进货每件单价")
        let n = try Limits.baseQty(packQty: packQty, packCount: packCount)
        let total = try Limits.lineAmount(unitFen: unitCostFen.raw, packCount: packCount)
        baseQty = n
        totalFen = Fen(total)
        batchUnitCostFen = Fen(try roundDiv(total, n))
        let after = try stockBefore.map { try Checked.add($0, n) }
        newStockQty = after
        if let b = baseline, b.costKnown, let before = stockBefore, before > 0, let after {
            averageCostFen = Fen(try roundDiv(try Checked.add(b.stockValueFen.raw, total), after))
        } else {
            averageCostFen = nil
        }
    }

    public init(conversion: PackConversion, packCount: Int64, unitCostFen: Fen, baseline: ProductPrivate?,
                stockBefore: Int64?) throws {
        try self.init(packQty: conversion.packQty, packCount: packCount, unitCostFen: unitCostFen, baseline: baseline,
                      stockBefore: stockBefore)
    }
}

extension CalendarDate {
    /// 生产日期 + 保质期月数（§5.4）：按日历月加，月末对齐（1/31 + 1 个月 = 2/28 或 2/29）
    public func adding(months: Int64) throws -> CalendarDate {
        guard (1...Limits.maxShelfLifeMonths).contains(months) else { throw invalid("保质期月数超出 1…\(Limits.maxShelfLifeMonths)") }
        let total = Int64(year) * 12 + Int64(month - 1) + months
        let y = Int(total / 12), m = Int(total % 12) + 1
        guard y <= 9999 else { throw invalid("算出来的到期日超过 9999 年") }
        return try CalendarDate(year: y, month: m, day: min(day, CalendarDate.daysIn(year: y, month: m)))
    }
}
