import Foundation
import ShopCore

/// 卖出页的测试夹具（截图、UI 测试用）。正式构建里永远是空的：解析只编译进 Debug（§14 S15-7）。
struct SellFixture: Equatable, Sendable {
    /// 开页后由 `FakeScanner` 喂码（`-uiScan` 等参数，见 `FakeScanner`；只在 Debug）
    var scanner: ScannerFeed?
    /// 喂完码后把实收改成这个数（代替 S17 的抹零面板，03b 截图用）
    var paidFen: Int64?
    /// 喂完后自动按「记账」（03d 截图用）
    var autoCommit = false
    /// 「记好了」黑卡不自动消失（截图用）
    var holdDone = false
    /// 把相机权限当成这个值（`-uiCamera`，27a）。夹具启动没给时当作允许：模拟器没有相机，
    /// 不能让系统的相机询问框挡住 UI 测试和截图
    var camera: CameraAccess?
    /// 在页面上放调试探针 `debug.ledger`
    var probe = false
    /// 喂完后打开抹零面板（18），按这几个键（「5」「53.5」），要不要再按「就收这么多」（28 截图）
    var openDiscount = false
    var discountKeys: String?
    var discountSubmit = false
    /// 喂完后推到手输条码页（15 / 15b）
    var openManual = false
    var manual = ManualFixture.none

    static let none = SellFixture()
}

#if DEBUG
typealias ScannerFeed = FakeScanner
#else
/// 正式构建里没有 FakeScanner：这个类型只占位，永远是 nil
struct ScannerFeed: Equatable, Sendable {}
#endif

#if DEBUG
extension SellFixture {
    /// 启动参数：
    ///   -uiScan … / -uiScanSource / -uiScanGap / -uiScanDelay   交给 `FakeScanner`（默认当扫码枪，开页等 1 秒，每码 0.3 秒）
    ///   -uiPaid 5300             喂完把实收改成 5300 分
    ///   -uiAutoCommit            喂完自动记账
    ///   -uiHoldDone              「记好了」不自动消失
    ///   -uiCamera denied|authorized|notDetermined   `CameraPermission.forcedAccess`；不给时当作 authorized
    ///   -uiProbe                 放调试探针
    ///   -uiDiscount [键]         喂完打开抹零面板并按这些键（例如 5、53.5）；-uiDiscountSubmit 再按「就收这么多」
    ///   -uiManual [code|name]    喂完推到手输条码页；-uiManualInput 69025143 / -uiManualQuery 康师傅 / -uiManualSelect 0
    @MainActor static func from(_ args: [String]) -> SellFixture {
        var f = SellFixture()
        f.scanner = FakeScanner.from(args)
        f.paidFen = UIFixture.value(for: "-uiPaid", in: args).flatMap { Int64($0) }
        f.autoCommit = args.contains("-uiAutoCommit")
        f.holdDone = args.contains("-uiHoldDone")
        f.camera = CameraPermission.forcedAccess(from: args) ?? .authorized
        f.probe = args.contains("-uiProbe")
        if let i = args.firstIndex(of: "-uiDiscount") {
            f.openDiscount = true
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") { f.discountKeys = args[i + 1] }
        }
        f.discountSubmit = args.contains("-uiDiscountSubmit")
        if let i = args.firstIndex(of: "-uiManual") {
            f.openManual = true
            if i + 1 < args.count { f.manual.tab = ManualCodeModel.Tab(rawValue: args[i + 1]) }
        }
        f.manual.input = UIFixture.value(for: "-uiManualInput", in: args)
        f.manual.query = UIFixture.value(for: "-uiManualQuery", in: args)
        f.manual.selectIndex = UIFixture.value(for: "-uiManualSelect", in: args).flatMap(Int.init)
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
                    "lastAmounts=\(last.map { String($0.amountFen.raw) }.joined(separator: "|"))",
                    "lastQty=\(qty)", "saleOps=\(ops.count)", "commits=\(commits)"].joined(separator: ";")
        } catch {
            return "error=\(error)"
        }
    }
}
#endif
