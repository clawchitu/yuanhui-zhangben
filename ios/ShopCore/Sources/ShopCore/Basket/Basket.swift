import Foundation

/// 卖出页的购物篮（设计稿 03）。纯值类型，不碰界面和存储。
public struct Basket: Hashable, Sendable {
    public struct Line: Hashable, Sendable, Identifiable {
        /// 这一行将来写成流水的 id（§4.3 `entry_id`，手机生成）
        public let id: UUID
        public let conversion: PackConversion
        public private(set) var packCount: Int64

        public var productId: UUID { conversion.product.id }
        public var barcode: String { conversion.barcode.barcode }
        public var name: String { conversion.product.name }
        public var unitName: String { conversion.barcode.unitName }
        public var packQty: Int64 { conversion.packQty }
        public func unitPrice() throws -> Fen { try conversion.unitPrice() }
        /// 小计 = 单价 × 件数（§5.0 单行上限）
        public func listAmount() throws -> Fen {
            Fen(try Limits.lineAmount(unitFen: try unitPrice().raw, packCount: packCount))
        }
        /// 基本单位数量（扫整箱码 1 件 = 24 个）
        public func baseQty() throws -> Int64 { try conversion.baseQty(packCount: packCount) }

        fileprivate init(id: UUID, conversion: PackConversion, packCount: Int64) {
            self.id = id; self.conversion = conversion; self.packCount = packCount
        }
        fileprivate mutating func setCount(_ n: Int64) { packCount = n }
    }

    public private(set) var lines: [Line] = []
    /// 改过的实收；nil = 不抹零，按原价收
    public private(set) var paidOverrideFen: Fen?

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }

    /// 扫到一个码：合并键「商品 + 换算数量 + 这一件的卖价 + 单位名」全部相同（同码，或同一商品的另一个单件码）
    /// 就在那一行 +件数，否则新加一行（§14 S12-2）。同换算但价钱或叫法不同的两个整件码是两行、各收各的价。
    /// 返回这一行的下标。加完后超出 §5.0 上限就拒，篮子不变。
    @discardableResult
    public mutating func add(_ conv: PackConversion, packCount: Int64 = 1, lineId: UUID = UUID()) throws -> Int {
        guard packCount >= 1 else { throw invalid("件数至少为 1") }
        let key = try MergeKey(conv)
        if let i = try lines.firstIndex(where: { try MergeKey($0.conversion) == key }) {
            try setCount(at: i, try Checked.add(lines[i].packCount, packCount))
            return i
        }
        guard lines.count < Limits.maxSaleLines else { throw invalid("一笔卖出最多 \(Limits.maxSaleLines) 行") }
        let line = Line(id: lineId, conversion: conv, packCount: packCount)
        try Self.validate(line)
        lines.append(line)
        return lines.count - 1
    }

    /// 改件数；减到 0 删掉这一行（S16）。
    public mutating func setCount(at index: Int, _ n: Int64) throws {
        guard lines.indices.contains(index) else { throw invalid("没有这一行") }
        if n <= 0 { lines.remove(at: index); return }
        var l = lines[index]
        l.setCount(n)
        try Self.validate(l)
        lines[index] = l
    }

    public mutating func remove(at index: Int) { if lines.indices.contains(index) { lines.remove(at: index) } }

    public mutating func clear() { lines.removeAll(); paidOverrideFen = nil }

    /// 购物篮合并键（§14 S12-2；§5.5 的候选去重用同一个键）
    struct MergeKey: Hashable {
        let productId: UUID
        let packQty: Int64
        let unitPriceFen: Fen
        let unitName: String
        init(_ c: PackConversion) throws {
            productId = c.product.id; packQty = c.packQty; unitPriceFen = try c.unitPrice(); unitName = c.barcode.unitName
        }
    }

    private static func validate(_ l: Line) throws {
        _ = try l.listAmount()
        _ = try l.baseQty()
    }

    /// 一共几件（设计稿 03「一共 6 件」）
    public var itemCount: Int64 { lines.reduce(0) { $0 + $1.packCount } }

    /// 原价合计（设计稿 03「要收 ¥53.50」）
    public func listTotal() throws -> Fen {
        Fen(try Checked.sum(try lines.map { try $0.listAmount().raw }))
    }

    /// 要收：改过就是改过的数，否则原价
    public func paidTotal() throws -> Fen { try paidOverrideFen ?? listTotal() }

    /// 全是零价商品时改价按钮不可用（§5.1 第 0 步）
    public func canChangePaid() throws -> Bool {
        guard !lines.isEmpty else { return false }
        return try listTotal() > .zero
    }

    /// 抹零 / 改总价。nil = 不抹了，恢复原价。超出实收上限或在全零购物篮上改价时拒。
    public mutating func setPaid(_ fen: Fen?) throws {
        guard let fen else { paidOverrideFen = nil; return }
        try Limits.checkPaidTotal(fen.raw)
        if try listTotal() == .zero, fen != .zero { throw invalid("全是零价商品，不能改价") }
        paidOverrideFen = fen
    }

    /// 实收低于原价七折、或高于原价时要二次确认（§5.1 抹零面板，设计稿 18、28）。
    /// 「低于七折」：P × 10 < L × 7，全整数比较。
    public func needsPaidConfirmation() throws -> Bool {
        guard let p = paidOverrideFen else { return false }
        let l = try listTotal()
        if p > l { return true }
        return try Checked.mul(p.raw, 10) < Checked.mul(l.raw, 7)
    }

    /// 按 §5.1 分摊后的各行实收（界面显示用；服务器另算一遍，向量保证一致）
    public func allocation() throws -> Allocation.Result {
        try Allocation.allocate(lines: try allocationLines(), paidTotalFen: try paidTotal().raw)
    }

    func allocationLines() throws -> [Allocation.Line] {
        try lines.map { Allocation.Line(unitPriceFen: try $0.unitPrice().raw, packCount: $0.packCount, packQty: $0.packQty) }
    }

    /// 记账：生成 `sale_batch` 的 payload（原价和分摊由服务器算，这里先按同一规则校验一遍）。
    public func makeSaleBatch(batchId: UUID = UUID()) throws -> SaleBatchPayload {
        guard !lines.isEmpty else { throw invalid("购物篮是空的") }
        _ = try allocation()
        return try SaleBatchPayload(
            batchId: batchId,
            paidTotalFen: try paidTotal(),
            lines: try lines.map {
                try SaleLine(entryId: $0.id, productId: $0.productId, barcode: $0.barcode, name: $0.name,
                             unitName: $0.unitName, packQty: $0.packQty, packCount: $0.packCount,
                             unitPriceFen: try $0.unitPrice())
            })
    }
}
