import Foundation
import ShopCore

/// `-uiFixture` 机制：用启动参数直接打开某个界面（截图、UI 测试用），不走登录和同步。
///
/// 所有构建都认的（只换界面状态、不碰会话，§14 S15-7）：
///   -uiFixture gallery | gallery-1 … gallery-5   组件陈列页（全部 / 第 n 页）
///   -uiLargeText on | off                        覆盖「大字模式」设置
///
/// 只在 Debug 构建里编译进去的（会开出会话、换身份或装演示数据，§14 S15-4 / S15-7）：
///   -uiFixture home | home-unsynced              首页（01 / 02 / 25a；已做完首次进入）
///   -uiFixture onboarding                        首次进入（16 / 16b）
///   -uiFixture settings                          设置（21a / 21b）
///   -uiRole family | cashier | review            用内存库 + 演示数据，以这个身份开会话（默认 family）
///   -uiRoute stockIn,settings,…                  开好后把这些路由直接塞进导航栈（测「硬塞路由也进不去」）
///   -uiFreshInstall                              当作刚装好：清掉本机的字号选择和「首次进入做完了」
///   -uiScrollTo bottom                           首页打开后滚到底（截长页用）
///   -uiPriorSales N                              先记 N 笔卖出（03 顶栏「2 笔待传」）
///   -uiLongName                                  多登记一个名字很长、单价很高的商品（码 6900000000017）
///   -uiRecords | -uiRecords none                S20：装上稿子 07a / 07b / 07c 的账（none = 一笔都没有，但「刚记的」走真数据）
///   -uiRecordsTab yesterday|earlier、-uiRecordsDay N   记的账页一打开就切到这一栏 / 点开 07c 第 N 天
///   -uiMoreGoods                                 S17：多登记同前缀的面、几样牛奶、一个零价购物袋（见 `installSellExtras`）
///   -uiFixture scanner | scanner-login           扫码测试页（27a / 27b 的样子，S14）
///   -uiCamera denied|authorized|notDetermined    把相机权限当成这个值（S14；卖出页同样认）
///   -uiScan / -uiScanSource / -uiScanGap / -uiScanDelay   FakeScanner 喂码，见 `FakeScanner`（S14；卖出页同样认）
///   卖出页的 -uiPaid / -uiAutoCommit / -uiHoldDone / -uiProbe 见 `SellFixture`
/// Beta / Release 里这些参数一律不认：没有会话就出「还没登录」页。
enum UIFixture {
    enum Screen: Equatable {
        case gallery(page: Int?)
        #if DEBUG
        case home(unsynced: Bool)
        case onboarding
        case settings
        case scanner(login: Bool)
        #endif
    }

    static func screen(from args: [String]) -> Screen? {
        guard let value = value(for: "-uiFixture", in: args) else { return nil }
        if value == "gallery" { return .gallery(page: nil) }
        if value.hasPrefix("gallery-"), let page = Int(value.dropFirst("gallery-".count)) {
            return .gallery(page: page)
        }
        #if DEBUG
        switch value {
        case "home": return .home(unsynced: false)
        case "home-unsynced": return .home(unsynced: true)
        case "onboarding": return .onboarding
        case "settings": return .settings
        case "scanner": return .scanner(login: false)
        case "scanner-login": return .scanner(login: true)
        default: break
        }
        #endif
        return nil
    }

    static func largeTextOverride(from args: [String]) -> Bool? {
        switch value(for: "-uiLargeText", in: args) {
        case "on": true
        case "off": false
        default: nil
        }
    }

    static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func applyLaunchOverrides(_ args: [String] = ProcessInfo.processInfo.arguments,
                                     defaults: UserDefaults = .standard) {
        #if DEBUG
        if args.contains("-uiFreshInstall") {
            defaults.removeObject(forKey: AppSettings.largeTextModeKey)
            defaults.removeObject(forKey: AppSettings.onboardedDeviceKey)
        }
        #endif
        if let on = largeTextOverride(from: args) {
            defaults.set(on, forKey: AppSettings.largeTextModeKey)
        }
    }
}

extension UIFixture.Screen {
    var isGallery: Bool {
        if case .gallery = self { return true }
        return false
    }
}

#if DEBUG
/// 下面这些会开出会话（换身份、装演示数据），只在 Debug 构建里有（§14 S15-4 / S15-7）。
extension UIFixture {
    static func role(from args: [String]) -> Role? {
        guard let v = value(for: "-uiRole", in: args) else {
            // 有界面夹具但没写身份：默认家用
            if let s = screen(from: args), !s.isGallery { return .family }
            return nil
        }
        return Role(rawValue: v).flatMap { $0 == .revoked ? nil : $0 }
    }

    /// `-uiRoute a,b`：开好后直接塞进导航栈的路由（认不出的名字忽略）
    static func injectedRoutes(from args: [String]) -> [Route] {
        guard let v = value(for: "-uiRoute", in: args) else { return [] }
        return v.split(separator: ",").compactMap { Route(rawValue: String($0)) }
    }

    /// 演示会话的设备 id：每种身份固定一个，重启后「首次进入做完了」仍认得这台手机
    static func demoDeviceId(_ role: Role) -> UUID {
        switch role {
        case .family: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F001")!
        case .cashier: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F002")!
        case .review, .revoked: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F003")!
        }
    }

    /// 稿子上的时间：2026-11-19 星期四 19:48（上海）
    static let designNow = Date(timeIntervalSince1970: 1_795_088_880)

    /// 长名商品的码（S16 验收：商品名很长时换行不截断、金额不出右边距）
    static let longNameBarcode = "6900000000017"
    static let longName = "贵州茅台酒（飞天）53%vol 500ml 礼盒装 附赠两只小酒杯 生肖纪念版"

    /// `-uiMoreGoods` 加的码：和康师傅红烧牛肉面（6902514300011）同前缀的另一个商品、零价商品
    static let sameMakerBarcode = "6902514300028"
    static let zeroPriceBarcode = "6900000000024"
    /// S20 夹具：稿子 07a（家用）/ 07b（收银员）/ 07c 的账。返回首页「刚记的」是否走真数据
    static func installRecords(into db: LocalDB, session s: LocalSession, args: [String]) throws -> Bool {
        guard let i = args.firstIndex(of: "-uiRecords") else { return false }
        if i + 1 < args.count, args[i + 1] == "none" { return true }
        func at(_ hm: String, daysAgo: Int = 0) -> Date {
            let p = hm.split(separator: ":").compactMap { Double($0) }
            // designNow = 19:48
            return designNow.addingTimeInterval((p[0] - 19) * 3600 + (p[1] - 48) * 60 - Double(daysAgo) * 86_400)
        }
        func sale(_ items: [(String, Int)], paid: Int64?, at t: Date) throws {
            var b = Basket()
            for (code, n) in items {
                guard let c = try db.lookup(barcode: code) else { continue }
                for _ in 0..<n { try b.add(c) }
            }
            if let paid { try b.setPaid(Fen(paid)) }
            try db.recordSale(b, at: t)
        }
        let dad = UUID(uuidString: "5EED0000-0000-4000-8000-00000000F0DA")!
        try db.setDeviceLabels([dad: "爸爸的手机"])
        var seq: Int64 = 1
        func pulledSale(_ name: String, _ n: Int64, _ fen: Int64, at t: Date, device: UUID, voided: Date? = nil) -> (PulledBatch, [PulledEntry]) {
            let b = UUID(), op = UUID(), e = UUID(); seq += 2
            var rows = [PulledEntry(id: e, seq: seq, opId: op, batchId: b, productId: DemoSeedIds.water, name: name,
                                    amounts: EntryAmounts(type: .sale, qtyDelta: -n, amountFen: fen, listAmountFen: fen, packQty: 1, packCount: n),
                                    deviceId: device, occurredAt: t, voidedAt: voided)]
            if let voided {
                rows.append(PulledEntry(seq: seq + 1, opId: UUID(), batchId: b, reversesEntryId: e, productId: DemoSeedIds.water, name: name,
                                        amounts: try! EntryAmounts(type: .sale, qtyDelta: -n, amountFen: fen, listAmountFen: fen, packQty: 1, packCount: n).reversal(),
                                        deviceId: device, occurredAt: voided))
            }
            return (PulledBatch(id: b, deviceId: device, listTotalFen: fen, paidTotalFen: fen, occurredAt: t), rows)
        }
        var batches: [PulledBatch] = [], entries: [PulledEntry] = []
        if s.holdsPrivateData {
            // 07a：18:10 爸爸的手机进货可乐 5 箱 ¥240；18:55 本机过期扔掉桃李 2 个（按进价 ¥6.40）
            entries.append(PulledEntry(seq: 1, opId: UUID(), productId: DemoSeedIds.cola, name: "可口可乐 330ml", unitName: "箱",
                                       amounts: EntryAmounts(type: .stockIn, qtyDelta: 120, amountFen: 24000, listAmountFen: 24000, cogsFen: 0,
                                                             valueDeltaFen: 24000, unitCostFen: 200, packQty: 24, packCount: 5),
                                       deviceId: dad, occurredAt: at("18:10")))
            entries.append(PulledEntry(seq: 2, opId: UUID(), productId: UUID(), name: "桃李 醇熟切片面包", unitName: "袋",
                                       amounts: EntryAmounts(type: .expireLoss, qtyDelta: -2, amountFen: 0, listAmountFen: 0, cogsFen: 0,
                                                             valueDeltaFen: -640, packQty: 1, packCount: 2),
                                       deviceId: s.deviceId, occurredAt: at("18:55")))
            // 07c：11/17 往前每天的笔数和金额（稿子上的数）；昨天 11/18 也记几笔
            let days: [(Int, Int, Int64)] = [(1, 12, 36_000), (2, 32, 110_200), (3, 41, 128_650), (4, 58, 147_900), (5, 55, 144_400),
                                             (6, 37, 107_100), (7, 40, 126_800), (8, 33, 115_000), (9, 28, 90_000), (12, 30, 99_000)]
            for (ago, n, total) in days {
                let each = total / Int64(n)
                for k in 0..<n {
                    let fen = k == 0 ? total - each * Int64(n - 1) : each
                    let (b, e) = pulledSale("农夫山泉 550ml", 1, fen, at: at("09:00", daysAgo: ago).addingTimeInterval(Double(k) * 600),
                                            device: k % 3 == 0 ? dad : s.deviceId)
                    batches.append(b); entries += e
                }
            }
        } else {
            // 07b：17:48 旺仔牛奶 ¥5.00（已撤销）；19:05 农夫山泉 ×2 + 乐事薯片 ×1 = ¥11.50
            let (b1, e1) = pulledSale("旺仔牛奶 245ml", 1, 500, at: at("17:48"), device: s.deviceId, voided: at("17:50"))
            let b2 = UUID(), op2 = UUID()
            seq += 10
            batches += [b1, PulledBatch(id: b2, deviceId: s.deviceId, listTotalFen: 1150, paidTotalFen: 1150, occurredAt: at("19:05"))]
            entries += e1
            entries += [
                PulledEntry(seq: seq, opId: op2, batchId: b2, productId: DemoSeedIds.water, name: "农夫山泉 550ml",
                            amounts: EntryAmounts(type: .sale, qtyDelta: -2, amountFen: 400, listAmountFen: 400, packQty: 1, packCount: 2),
                            deviceId: s.deviceId, occurredAt: at("19:05")),
                PulledEntry(seq: seq + 1, opId: op2, batchId: b2, productId: UUID(), name: "乐事薯片 原味 70g",
                            amounts: EntryAmounts(type: .sale, qtyDelta: -1, amountFen: 750, listAmountFen: 750, packQty: 1, packCount: 1),
                            deviceId: s.deviceId, occurredAt: at("19:05")),
            ]
            // 昨天本机的一笔（07b 不列、也撤不了）
            let (b3, e3) = pulledSale("农夫山泉 550ml", 1, 200, at: at("10:00", daysAgo: 1), device: s.deviceId)
            batches.append(b3); entries += e3
        }
        try db.applyPulledLedger(batches: batches, entries: entries)
        // 19:32 本机的卖出（稿子 03 / 08：53.50 抹到 53.00），还没传上去
        try sale([("6901234500011", 1), ("6901035600016", 4), ("6902514300011", 1)], paid: 5300, at: at("19:32"))
        return true
    }

    enum DemoSeedIds {
        static let water = UUID(uuidString: "5EED0000-0000-4000-8000-000000000206")!
        static let cola = UUID(uuidString: "5EED0000-0000-4000-8000-000000000204")!
    }

    /// 卖出页要用的额外夹具：长名商品、事先记好的几笔卖出
    static func installSellExtras(into db: LocalDB, args: [String]) throws {
        if args.contains("-uiLongName") {
            let p = try Product(id: UUID(uuidString: "5EED0000-0000-4000-8000-0000000002FF")!, name: longName, baseUnit: "瓶",
                                priceFen: Fen(999_999))
            try db.applyBaseline(CatalogBaseline(products: [p], barcodes: [
                try BarcodeRecord(barcode: longNameBarcode, productId: p.id, packQty: 1, unitName: "瓶", packPriceFen: nil)]))
        }
        if args.contains("-uiMoreGoods") {
            // S17：同厂商另一个面（前缀 69025143 命中两个商品，prefix.json 同款）、按名称找的几样牛奶、一个零价商品
            let items: [(Int, String, String, Int64, String)] = [
                (0x301, "康师傅老坛酸菜牛肉面", "桶", 450, sameMakerBarcode),
                (0x302, "伊利纯牛奶 250ml", "盒", 350, "6907992100012"),
                (0x303, "光明 新鲜牧场 950ml", "瓶", 1380, "6901209200014"),
                (0x304, "旺仔牛奶 245ml", "罐", 500, "6902083800016"),
                (0x305, "购物袋（送的）", "个", 0, zeroPriceBarcode),
            ]
            var products: [Product] = [], codes: [BarcodeRecord] = []
            for (n, name, unit, price, code) in items {
                let p = try Product(id: UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012X", n))!, name: name,
                                    baseUnit: unit, priceFen: Fen(price))
                products.append(p)
                codes.append(try BarcodeRecord(barcode: code, productId: p.id, packQty: 1, unitName: unit, packPriceFen: nil))
            }
            try db.applyBaseline(CatalogBaseline(products: products, barcodes: codes))
        }
        if let n = value(for: "-uiPriorSales", in: args).flatMap(Int.init), n > 0 {
            guard let water = try db.lookup(barcode: "6921168509256") else { return }
            for i in 0..<n {
                var b = Basket()
                try b.add(water)
                try db.recordSale(b, at: designNow.addingTimeInterval(TimeInterval(-600 * (n - i))))
            }
        }
    }
}
#endif

