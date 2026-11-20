/// 手输条码的前缀匹配（§5.5，规则）。纯函数：输入是「条码以输入为前缀」的全部换算，输出候选。
/// 本地库查出前缀命中的条码后交给它；`contracts/vectors/prefix.json` 直接测它和本地库两层。
public enum BarcodeMatch {
    /// 满几位才开始列（§5.5）
    public static let minPrefixLength = 8
    /// 最多显示几行
    public static let maxShown = 4

    public struct Candidate: Hashable, Sendable {
        /// 代表条码：有与输入完全相等的取它，否则取匹配条码里字符串最小的（§14 R3）。排序、显示、加入购物篮都用它
        public let conversion: PackConversion
        /// 这个候选下所有匹配的条码（同一商品的两个单件码）
        public let matchedBarcodes: [String]
        public var representativeBarcode: String { conversion.barcode.barcode }
    }

    public struct Result: Hashable, Sendable {
        /// 输入满 8 位才为真
        public let listed: Bool
        public let candidates: [Candidate]
        /// 前 4 个
        public var shown: [Candidate] { Array(candidates.prefix(BarcodeMatch.maxShown)) }
        /// 「还有 N 个，接着输」
        public var moreCount: Int { max(0, candidates.count - BarcodeMatch.maxShown) }
        /// 只剩一个候选才自动选中；绝不自动选第一个
        public var autoSelect: Candidate? { candidates.count == 1 ? candidates[0] : nil }
        public static let notListed = Result(listed: false, candidates: [])
    }

    /// `matches` 里每个条码都应以 `input` 为前缀（不是的会被过滤掉）。
    /// 去重键与购物篮合并键相同：「商品 + 换算数量 + 这一件的卖价 + 单位名」（§14 S12-2）。
    /// 同一商品的两个单件码 → 一个候选；同一商品的单件码和整箱码 → 两个候选。
    public static func match(input: String, among matches: [PackConversion]) throws -> Result {
        guard input.count >= minPrefixLength else { return .notListed }
        var groups: [Basket.MergeKey: [PackConversion]] = [:]
        var order: [Basket.MergeKey] = []
        for c in matches where c.barcode.barcode.hasPrefix(input) {
            let k = try Basket.MergeKey(c)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(c)
        }
        let candidates = order.map { k -> Candidate in
            let group = groups[k]!
            let rep = group.first { $0.barcode.barcode == input }
                ?? group.min { $0.barcode.barcode < $1.barcode.barcode }!
            return Candidate(conversion: rep, matchedBarcodes: group.map(\.barcode.barcode).sorted())
        }
        let sorted = candidates.sorted { a, b in
            let ea = a.representativeBarcode == input, eb = b.representativeBarcode == input
            if ea != eb { return ea }
            if a.representativeBarcode != b.representativeBarcode { return a.representativeBarcode < b.representativeBarcode }
            return a.conversion.packQty < b.conversion.packQty
        }
        return Result(listed: true, candidates: sorted)
    }
}
