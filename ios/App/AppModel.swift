import Foundation
import Observation
import ShopCore

/// 首页和设置页上显示的几个数。S15 只有界面：待传笔数、快过期样数、「刚记的」、设置页右侧的小字
/// 在 `-uiFixture` 下用稿子上的数；正常启动时只有待传笔数来自本地库，其余在后面的段接真数据
/// （刚记的 → S20，快过期 → S27，同步状态 → S22a，已登录的手机 → S23a）。扫码枪连接状态 S16 起来自
/// `ScannerGunMonitor`（见 `AppModel.scannerConnected`）。
struct HomeFigures: Equatable, Sendable {
    struct LastRecord: Equatable, Sendable {
        var time: String          // "19:32"
        var kind: String          // "卖出"
        var itemCount: Int        // 3 样
        var amountFen: Int        // 5300
    }

    /// 待传笔数；nil = 不显示同步状态，0 = 已同步
    var pendingCount: Int? = 0
    /// 超过一天没传上去的笔数（25a 的提醒条）
    var staleUnsyncedCount = 0
    /// 快过期的样数（01 的黄条、21a 的「快过期的」）
    var expiringCount = 0
    var lastRecord: LastRecord?
    /// 21a 右侧小字
    var countSummary: String?       // "11月 数了 86 种"
    var deviceCount: Int?           // 3 台
    /// 扫码枪 已连上 / 没连：只有夹具用稿子上的值；nil = 用真实的连接状态（`ScannerGunMonitor`）
    var scannerConnected: Bool?

    /// 设计稿 01 / 02 / 21a 上的数
    static let design = HomeFigures(pendingCount: 0, staleUnsyncedCount: 0, expiringCount: 3,
                                    lastRecord: .init(time: "19:32", kind: "卖出", itemCount: 3, amountFen: 5300),
                                    countSummary: "11月 数了 86 种", deviceCount: 3, scannerConnected: true)
}

extension HomeFigures.LastRecord {
    /// 本地库最近一张卡 → 首页「刚记的 19:32 / 卖出 3 样 ¥53.00」
    init(_ c: RecordCard) {
        self.init(time: c.time, kind: c.kindText, itemCount: c.openLines.count, amountFen: Int(c.amountFen ?? 0))
    }
}

/// 首页提醒条（25a）。规则：「没同步」在「快过期」上面。
enum HomeReminder: Hashable, Sendable {
    case unsynced(Int)
    case expiring(Int)

    /// 要显示哪些提醒、按什么顺序。快过期只给有「处理快过期」能力的手机（收银员没有黄条，S27）
    static func list(_ f: HomeFigures, capabilities: Capabilities) -> [HomeReminder] {
        var r: [HomeReminder] = []
        if f.staleUnsyncedCount > 0 { r.append(.unsynced(f.staleUnsyncedCount)) }
        if f.expiringCount > 0, capabilities.has(.expiry) { r.append(.expiring(f.expiringCount)) }
        return r
    }
}

/// 首页（01 / 02）、设置页（21a / 21b）和各页标题用哪种版式。所有地方都从 `AppModel.layout` 取，判断依据只有一个：
/// 有进货能力的是家用版式；没有的（收银员，以及被踢设备）一律收银员版式。
enum ShellLayout: Equatable, Sendable {
    case family, cashier

    init(_ capabilities: Capabilities) {
        self = capabilities.has(.stockIn) ? .family : .cashier
    }
}

/// App 的状态：当前会话（角色、店名、手机名）、能力表、首次进入有没有做完。
@MainActor @Observable
final class AppModel {
    private(set) var session: LocalSession
    private(set) var capabilities: Capabilities
    private(set) var onboarded: Bool
    var figures: HomeFigures
    let today: Date
    /// 夹具固定的「现在」（稿子上的时间）；正常启动为 nil，用真时间
    let fixedNow: Date?
    /// 「刚记的」从本地库取（正常启动，和带 `-uiRecords` 的夹具）；false = 夹具用稿子上的数
    var liveRecent = true
    var now: Date { fixedNow ?? Date() }
    /// `-uiScrollTo bottom`：首页一打开就滚到底（截最大辅助字号下的整页用）
    let scrollToBottom: Bool
    /// 卖出页的测试夹具（只在 Debug 下由启动参数填，正式构建永远是空的）
    var sellFixture = SellFixture.none
    /// 扫码枪连接状态（§14 S15-1：设置页「扫码枪」右侧的字接真实状态）
    let gun: ScannerGunMonitor

    let db: LocalDB
    private let defaults: UserDefaults

    var role: Role { session.role }
    /// 首页 / 设置页的版式（唯一来源）
    var layout: ShellLayout { ShellLayout(capabilities) }
    /// 设置页「扫码枪」右侧：夹具用稿子上的值，正常启动用真实的连接状态
    var scannerConnected: Bool { figures.scannerConnected ?? gun.connected }

    init(db: LocalDB, session: LocalSession, figures: HomeFigures, today: Date = Date(),
         defaults: UserDefaults = .standard, scrollToBottom: Bool = false, gun: ScannerGunMonitor = ScannerGunMonitor(),
         fixedNow: Date? = nil) {
        self.fixedNow = fixedNow
        self.db = db
        self.gun = gun
        self.session = session
        self.capabilities = Capabilities(role: session.role)
        self.figures = figures
        self.today = today
        self.defaults = defaults
        self.scrollToBottom = scrollToBottom
        self.onboarded = defaults.string(forKey: AppSettings.onboardedDeviceKey) == session.deviceId.uuidString
    }

    /// 16 / 16b「好了，开始用」：字号选择存在本机（UserDefaults），家用手机顺带改名。
    func finishOnboarding(largeText: Bool, deviceName: String?) throws {
        if let deviceName, capabilities.has(.renameDevice), deviceName != session.deviceLabel {
            try rename(deviceName)
        }
        defaults.set(largeText, forKey: AppSettings.largeTextModeKey)
        defaults.set(session.deviceId.uuidString, forKey: AppSettings.onboardedDeviceKey)
        onboarded = true
    }

    /// 首页「刚记的」和待传笔数从本地库重取（§14 S15-1：刚记的接真数据，S20）
    func refreshRecent() {
        guard liveRecent else { return }
        figures.lastRecord = (try? db.lastRecord()).flatMap { $0.map(HomeFigures.LastRecord.init) } ?? nil
        if let n = try? db.pendingOps().count { figures.pendingCount = n }
    }

    func rename(_ name: String) throws {
        try db.renameCurrentDevice(name)
        if let s = try db.currentSession() { session = s }
    }
}
