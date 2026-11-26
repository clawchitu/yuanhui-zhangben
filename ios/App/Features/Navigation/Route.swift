import ShopCore
import SwiftUI

/// 首页能去的每一个地方（§6.2）。入口按角色的能力表决定有没有；`RouteView` 再挡一次（直接塞路由也进不去）。
/// 还没做的页面先放占位页，`plannedIn` 写着哪一段做。
enum Route: String, Hashable, CaseIterable, Sendable {
    case sell            // 03 系列
    case manualCode      // 15 / 15b 手输条码（从卖出页进）
    case discount        // 18 抹零 / 改总价（从卖出页进）
    case stockIn         // 06 系列
    case reports         // 09 / 10 看账
    case products        // 11 商品
    case settings        // 21a 更多 / 21b 设置
    case records         // 07a / 07b 记的账
    case undoLast        // 「记错了」→ 08 撤销
    case expiry          // 19 快过期
    case count           // 12 盘点
    case pairing         // 17a / 17b 开通
    case devices         // 已登录的手机
    case held            // 待确认的账（被退出的手机补传的，S23a）
    case deviceName      // 这台手机的名字
    case scanner         // 扫码枪
    case account         // 账号与密码、注销（23）
    case privacy         // 隐私政策
    case logout          // 退出登录
    case pending         // 待传的账（首页顶栏的同步状态、25a 提醒条点进来）

    /// 进这一页需要的能力；nil = 三种身份都能进
    var requiredCapability: Capability? {
        switch self {
        case .sell, .manualCode, .discount: .sell
        case .stockIn: .stockIn
        case .reports: .viewReports
        case .products: .manageProducts
        case .undoLast: .void
        case .expiry: .expiry
        case .count: .count
        case .pairing: .pairing
        case .devices: .manageDevices
        case .held: .heldOps
        case .deviceName: .renameDevice
        case .account: .account
        case .settings, .records, .scanner, .privacy, .logout, .pending: nil
        }
    }

    func isAllowed(_ caps: Capabilities) -> Bool {
        requiredCapability.map(caps.has) ?? true
    }

    /// 页面根视图的辅助功能标识（UI 测试用它判断「到了哪一页」）
    var pageId: String { "page.\(rawValue)" }

    func title(_ layout: ShellLayout) -> String {
        switch self {
        case .sell: "卖出"
        case .manualCode: "手输条码"
        case .discount: "抹零 / 改总价"
        case .stockIn: "进货"
        case .reports: "看账"
        case .products: "商品"
        case .settings: layout == .cashier ? "设置" : "更多"
        case .records: layout == .cashier ? "我记的账" : "记的账"
        case .undoLast: "撤销"
        case .expiry: "快过期的"
        case .count: "盘点"
        case .pairing: "给家里人 / 收银员开通"
        case .devices: "已登录的手机"
        case .held: "待确认的账"
        case .deviceName: "这台手机的名字"
        case .scanner: "扫码枪"
        case .account: "账号与密码"
        case .privacy: "隐私政策"
        case .logout: "退出登录"
        case .pending: "待传的账"
        }
    }

    /// 还没做的页面在哪一段做（占位页上显示）
    var plannedIn: String? {
        switch self {
        case .reports: "S24"
        case .products: "S25"
        case .expiry: "S27"
        case .count: "S26"
        case .account: "S23b"
        case .privacy: "S21"
        case .logout, .pending, .pairing, .devices, .held: nil
        case .sell, .manualCode, .discount, .stockIn, .settings, .deviceName, .scanner, .records, .undoLast: nil
        }
    }

    /// 页面颜色：卖出朱红、进货靛青，其余中性
    var mode: ShopMode {
        switch self {
        case .sell, .manualCode, .discount: .sell
        case .stockIn: .stock
        default: .neutral
        }
    }
}

/// 根据路由出页面。没有能力的路由一律出「这台手机用不了」页，不出真页面。
struct RouteView: View {
    @Environment(AppModel.self) private var model
    let route: Route

    /// 这条路由在这些能力下出哪种页面（纯函数，单元测试逐个路由 × 身份测）
    enum Content: Equatable {
        case denied, sell, manualCode, discountEntry, stockIn, settings, deviceName, scanner, records, logout, pending, pairing, devices, held, placeholder
    }

    static func content(for route: Route, capabilities: Capabilities) -> Content {
        guard route.isAllowed(capabilities) else { return .denied }
        switch route {
        case .sell: return .sell
        case .manualCode: return .manualCode
        case .discount: return .discountEntry
        case .stockIn: return .stockIn
        case .settings: return .settings
        case .deviceName: return .deviceName
        case .scanner: return .scanner
        case .records, .undoLast: return .records
        case .logout: return .logout
        case .pending: return .pending
        case .pairing: return .pairing
        case .devices: return .devices
        case .held: return .held
        default: return .placeholder
        }
    }

    var body: some View {
        Group {
            switch Self.content(for: route, capabilities: model.capabilities) {
            case .denied: DeniedPage()
            case .sell: SellView(db: model.db, fixture: model.sellFixture)
            // 直接塞进来的手输页（不是从卖出页推的）：能查能选，选了只是关页面，没有购物篮可加
            case .manualCode: ManualCodeView(db: model.db)
            // 抹零面板要对着一个购物篮，只能从卖出页的「抹零 / 改总价」弹出；直接塞路由只出一句说明
            case .discountEntry: PlaceholderPage(route: route, layout: model.layout, message: "从卖出页的「抹零 / 改总价」进")
            case .stockIn: StockInView(db: model.db, clock: { [model] in model.now }, fixture: model.sellFixture)
            case .settings: SettingsView()
            case .deviceName: DeviceNameView()
            case .scanner: ScannerStatusView()
            case .records:
                RecordsView(db: model.db, cashier: model.layout == .cashier, route: route, clock: { [model] in model.now })
            case .logout: LogoutView()
            case .pending: PendingView(db: model.db, clock: { [model] in model.now })
            case .pairing: PairingView()
            case .devices: DevicesView()
            case .held: HeldListView()
            // 看账（S24 之前是占位页）：家用首页没有「刚记的」条时从这里进记的账（§14 S15-6）
            case .placeholder: PlaceholderPage(route: route, layout: model.layout, link: route == .reports ? .records : nil)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 还没做的页面：标题 + 「这一页在 Sxx 做」。
struct PlaceholderPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let route: Route
    let layout: ShellLayout
    var message = "这一页还在做"
    /// 占位页上额外给的一个入口（看账 → 记的账）
    var link: Route?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: route.title(layout), mode: route.mode, onBack: { dismiss() })
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "hammer")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.mute)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(TypeScale.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    if let s = route.plannedIn {
                        Text("开发计划 \(s) 段").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    }
                    if let link {
                        NavigationLink(value: link) {
                            Label(link.title(layout), systemImage: "list.bullet.rectangle")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Tokens.Palette.ink)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                        }
                        .buttonStyle(PressDimStyle())
                        .padding(.top, 20)
                        .accessibilityIdentifier("\(route.rawValue).\(link.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 20)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(route.pageId)
    }
}

/// 没有这个能力：不出真页面。正常情况下入口都不显示，这一页只在路由被硬塞进来时出现。
struct DeniedPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "用不了", onBack: { dismiss() })
            Text("这台手机用不了这个功能")
                .font(TypeScale.body)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.top, 80)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.denied")
    }
}
