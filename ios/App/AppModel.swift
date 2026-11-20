import Foundation
import Observation
import ShopCore

/// 首页和设置页上显示的几个数。S15 只有界面：待传笔数、快过期样数、「刚记的」、设置页右侧的小字
/// 在 `-uiFixture` 下用稿子上的数；正常启动时只有待传笔数来自本地库，其余在后面的段接真数据
/// （刚记的 → S20，快过期 → S27，同步状态 → S22a，已登录的手机 / 扫码枪 → S23a / S14）。
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
    var scannerConnected: Bool?     // 已连上 / 没连

    /// 设计稿 01 / 02 / 21a 上的数
    static let design = HomeFigures(pendingCount: 0, staleUnsyncedCount: 0, expiringCount: 3,
                                    lastRecord: .init(time: "19:32", kind: "卖出", itemCount: 3, amountFen: 5300),
                                    countSummary: "11月 数了 86 种", deviceCount: 3, scannerConnected: true)
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
    /// `-uiScrollTo bottom`：首页一打开就滚到底（截最大辅助字号下的整页用）
    let scrollToBottom: Bool
    /// 卖出页的测试夹具（只在 Debug 下由启动参数填，正式构建永远是空的）
    var sellFixture = SellFixture.none

    let db: LocalDB
    private let defaults: UserDefaults

    var role: Role { session.role }
    /// 首页 / 设置页的版式（唯一来源）
    var layout: ShellLayout { ShellLayout(capabilities) }

    init(db: LocalDB, session: LocalSession, figures: HomeFigures, today: Date = Date(),
         defaults: UserDefaults = .standard, scrollToBottom: Bool = false) {
        self.db = db
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

    func rename(_ name: String) throws {
        try db.renameCurrentDevice(name)
        if let s = try db.currentSession() { session = s }
    }
}
