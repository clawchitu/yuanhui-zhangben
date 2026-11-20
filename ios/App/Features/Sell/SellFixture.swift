import Foundation
import ShopCore

/// 卖出页的测试夹具（截图、UI 测试用）。正式构建里永远是空的：解析只编译进 Debug（§14 S15-7）。
struct SellFixture: Equatable, Sendable {
    /// 开页后依次喂进去的码（代替 S14 的扫码层）
    var scans: [String] = []
    /// 喂完码后把实收改成这个数（代替 S17 的抹零面板，03b 截图用）
    var paidFen: Int64?
    /// 喂完后自动按「记账」（03d 截图用）
    var autoCommit = false
    /// 「记好了」黑卡不自动消失（截图用）
    var holdDone = false
    /// 把相机权限当成这个值（27a）
    var camera: CameraAccess?
    /// 在页面上放调试探针 `debug.ledger`
    var probe = false

    static let none = SellFixture()
    var isEmpty: Bool { scans.isEmpty && paidFen == nil && !autoCommit }
}

#if DEBUG
extension SellFixture {
    /// 启动参数：
    ///   -uiScan 码,码,…          开页后依次喂码（同一个码写两次 = 扫两次）
    ///   -uiPaid 5300             喂完把实收改成 5300 分
    ///   -uiAutoCommit            喂完自动记账
    ///   -uiHoldDone              「记好了」不自动消失
    ///   -uiCamera denied|authorized|notDetermined
    ///   -uiProbe                 放调试探针
    static func from(_ args: [String]) -> SellFixture {
        var f = SellFixture()
        if let v = UIFixture.value(for: "-uiScan", in: args) {
            f.scans = v.split(separator: ",").map { String($0) }
        }
        f.paidFen = UIFixture.value(for: "-uiPaid", in: args).flatMap { Int64($0) }
        f.autoCommit = args.contains("-uiAutoCommit")
        f.holdDone = args.contains("-uiHoldDone")
        f.camera = UIFixture.value(for: "-uiCamera", in: args).flatMap(CameraAccess.init(rawValue:))
        f.probe = args.contains("-uiProbe")
        return f
    }
}

/// 调试探针的内容：本地库里的卖出批次和 outbox，UI 测试按 `key=value` 读。
enum SellProbe {
    static func describe(db: LocalDB, commits: Int) -> String {
        do {
            let sales = try db.entries().filter { $0.type == .sale }
            var batches: [UUID: [LocalEntry]] = [:]
            var order: [UUID] = []
            for e in sales.reversed() {   // entries() 新的在前；这里按记账先后
                guard let b = e.batchId else { continue }
                if batches[b] == nil { order.append(b) }
                batches[b, default: []].append(e)
            }
            let last = order.last.flatMap { batches[$0] } ?? []
            let ops = try db.allOutbox().filter { $0.type == .saleBatch }
            let qty = last.map { "\($0.name):\($0.packCount ?? 0)" }.joined(separator: "|")
            return ["batches=\(order.count)", "lastLines=\(last.count)",
                    "lastList=\(last.reduce(0) { $0 + $1.listAmountFen.raw })",
                    "lastPaid=\(last.reduce(0) { $0 + $1.amountFen.raw })",
                    "lastQty=\(qty)", "saleOps=\(ops.count)", "commits=\(commits)"].joined(separator: ";")
        } catch {
            return "error=\(error)"
        }
    }
}
#endif
