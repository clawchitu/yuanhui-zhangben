import Foundation
import ShopCore

/// 卖出页的测试夹具（截图、UI 测试用）。正式构建里永远是空的：解析只编译进 Debug（§14 S15-7）。
struct SellFixture: Equatable, Sendable {
    /// 开页后由 `FakeScanner` 喂码（`-uiScan` 等参数，见 `FakeScanner`；只在 Debug）
    var scanner: ScannerFeed?
    /// 喂完码后把实收改成这个数（代替 S17 的抹零面板，03b 截图用）
    var paidFen: Int64?
    /// 改完实收后再扫一个码（`-uiScanAfterPaid`，「抹的零取消了」黄条截图用）
    var scanAfterPaid: String?
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
    /// 查名称当作没网（25e，`-uiOffline`）
    var offline = false
    /// 登记页 / 05 预先填好的内容
    var newProduct = NewProductFixture.none

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
    ///   -uiScanAfterPaid 码     改完实收后再扫这个码（看「抹的零取消了」黄条）
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
        f.scanAfterPaid = UIFixture.value(for: "-uiScanAfterPaid", in: args)
        if let i = args.firstIndex(of: "-uiManual") {
            f.openManual = true
            if i + 1 < args.count { f.manual.tab = ManualCodeModel.Tab(rawValue: args[i + 1]) }
        }
        f.manual.input = UIFixture.value(for: "-uiManualInput", in: args)
        f.manual.query = UIFixture.value(for: "-uiManualQuery", in: args)
        f.manual.selectIndex = UIFixture.value(for: "-uiManualSelect", in: args).flatMap(Int.init)
        // S18：-uiOffline；登记页 -uiNewName / -uiNewPrice 7.5 / -uiNewStep2 / -uiNewCost / -uiNewQty / -uiNewExpiry 2027-05-20|on|unknown
        //      / -uiNewWarn 15 / -uiNewMode stock；05：-uiNewPack / -uiPackUnit 箱 / -uiPackQty 24 / -uiPackPrice 60
        f.offline = args.contains("-uiOffline")
        var n = NewProductFixture()
        n.name = UIFixture.value(for: "-uiNewName", in: args)
        n.price = UIFixture.value(for: "-uiNewPrice", in: args)
        n.step2 = args.contains("-uiNewStep2")
        n.cost = UIFixture.value(for: "-uiNewCost", in: args)
        n.qty = UIFixture.value(for: "-uiNewQty", in: args)
        n.expiry = UIFixture.value(for: "-uiNewExpiry", in: args)
        n.warnDays = UIFixture.value(for: "-uiNewWarn", in: args).flatMap(Int.init)
        n.pack = args.contains("-uiNewPack")
        n.packUnit = UIFixture.value(for: "-uiPackUnit", in: args)
        n.packQty = UIFixture.value(for: "-uiPackQty", in: args)
        n.packPrice = UIFixture.value(for: "-uiPackPrice", in: args)
        if UIFixture.value(for: "-uiNewMode", in: args) == "stock" { n.mode = .stock }
        f.newProduct = n
        return f
    }
}

/// 调试探针的内容：本地库里的卖出批次和 outbox，UI 测试按 `key=value` 读。
enum SellProbe {
    /// S18：登记、整件码、期初各进了几条 op（`quick` 的单独数）
    static func registrationCounts(_ db: LocalDB) -> [String] {
        let all = (try? db.allOutbox()) ?? []
        let upserts = all.filter { $0.type == .productUpsert }
        let quick = upserts.filter { String(decoding: $0.opJSON, as: UTF8.self).contains("\"quick\":true") }
        return ["upserts=\(upserts.count)", "quickUpserts=\(quick.count)",
                "links=\(all.filter { $0.type == .barcodeLink }.count)", "openings=\(all.filter { $0.type == .opening }.count)"]
    }

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
            let base: [String] = ["batches=\(order.count)", "lastLines=\(last.count)",
                    "lastList=\(last.reduce(0) { $0 + $1.listAmountFen.raw })",
                    "lastPaid=\(last.reduce(0) { $0 + $1.amountFen.raw })",
                    "lastAmounts=\(last.map { String($0.amountFen.raw) }.joined(separator: "|"))",
                    "lastQty=\(qty)", "saleOps=\(ops.count)", "commits=\(commits)",
                    "lastBase=\(last.reduce(Int64(0)) { $0 + $1.qtyDelta })"]
            return (base + registrationCounts(db)).joined(separator: ";")
        } catch {
            return "error=\(error)"
        }
    }
}
#endif
