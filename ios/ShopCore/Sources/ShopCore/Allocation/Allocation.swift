/// 优惠分摊（§5.1，规则；服务器和手机各实现一遍，`contracts/vectors/allocation.json` 一致）。
public enum Allocation {
    /// 一行的输入：单价（整件码就是整件价）、件数、换算（只用于基本单位数量上限）。
    public struct Line: Hashable, Sendable {
        public let unitPriceFen: Int64
        public let packCount: Int64
        public let packQty: Int64
        public init(unitPriceFen: Int64, packCount: Int64, packQty: Int64 = 1) {
            self.unitPriceFen = unitPriceFen; self.packCount = packCount; self.packQty = packQty
        }
    }

    public struct Result: Hashable, Sendable {
        /// 各行原价 `L_i = 单价 × 件数`
        public let listFen: [Int64]
        /// `L = Σ L_i`
        public let listTotalFen: Int64
        /// 各行摊完的实收 `a_i`，`Σ a_i = P`
        public let amountFen: [Int64]
    }

    /// 各行原价与合计，同时做 §5.0 的逐行上限校验（行数、单价、件数、单行金额、基本单位数量）。
    public static func listAmounts(_ lines: [Line]) throws -> (list: [Int64], total: Int64) {
        guard !lines.isEmpty else { throw invalid("购物篮是空的") }
        guard lines.count <= Limits.maxSaleLines else { throw invalid("一笔卖出最多 \(Limits.maxSaleLines) 行：\(lines.count)") }
        var list: [Int64] = []
        list.reserveCapacity(lines.count)
        for l in lines {
            try Limits.baseQty(packQty: l.packQty, packCount: l.packCount)
            list.append(try Limits.lineAmount(unitFen: l.unitPriceFen, packCount: l.packCount))
        }
        return (list, try Checked.sum(list))
    }

    /// 分摊。超限、实收为负或超上限、`L = 0` 而 `P ≠ 0` 时抛 `invalid`。
    public static func allocate(lines: [Line], paidTotalFen p: Int64) throws -> Result {
        let (list, total) = try listAmounts(lines)
        try Limits.checkPaidTotal(p)

        // 第 0 步：全零购物篮，P 必须为 0，各行 0
        if total == 0 {
            guard p == 0 else { throw invalid("全是零价商品时实收只能是 0") }
            return Result(listFen: list, listTotalFen: 0, amountFen: Array(repeating: 0, count: list.count))
        }

        // 第 1 步：a_i = roundDiv(L_i × P, L)（乘积最大约 2×10^18，在 Int64 内，仍做溢出检查）
        var a = try list.map { try roundDiv(try Checked.mul($0, p), total) }

        // 按原价降序、并列取最前的行顺序
        let order = list.indices.sorted { list[$0] != list[$1] ? list[$0] > list[$1] : $0 < $1 }

        // 第 2 步：d = P − Σa_i 加到原价最大的一行
        let d = try Checked.sub(p, try Checked.sum(a))
        a[order[0]] = try Checked.add(a[order[0]], d)

        // 第 3 步：该行因此小于 0 时设为 0，不足部分依次从下一大的行扣
        if a[order[0]] < 0 {
            var deficit = -a[order[0]]
            a[order[0]] = 0
            for i in order.dropFirst() where deficit > 0 {
                let take = min(a[i], deficit)
                a[i] -= take
                deficit -= take
            }
            // Σa_i = P ≥ 0，所以不足部分一定扣得完
            guard deficit == 0 else { throw invalid("分摊不足部分无法扣完") }
        }
        return Result(listFen: list, listTotalFen: total, amountFen: a)
    }
}
