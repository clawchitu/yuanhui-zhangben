import ShopCore
import SwiftUI

/// 首页能去的每一个地方（§6.2）。入口按角色的能力表决定有没有；`RouteView` 再挡一次（直接塞路由也进不去）。
/// 还没做的页面先放占位页，`plannedIn` 写着哪一段做。
enum Route: String, Hashable, CaseIterable, Sendable {
    case sell            // 03 系列
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
    case deviceName      // 这台手机的名字
    case scanner         // 扫码枪
    case account         // 账号与密码、注销（23）
    case privacy         // 隐私政策
    case logout          // 退出登录

    /// 进这一页需要的能力；nil = 三种身份都能进
    var requiredCapability: Capability? {
        switch self {
        case .sell: .sell
        case .stockIn: .stockIn
        case .reports: .viewReports
        case .products: .manageProducts
        case .undoLast: .void
        case .expiry: .expiry
        case .count: .count
        case .pairing: .pairing
        case .devices: .manageDevices
        case .deviceName: .renameDevice
        case .account: .account
        case .settings, .records, .scanner, .privacy, .logout: nil
        }
    }

    func isAllowed(_ caps: Capabilities) -> Bool {
        requiredCapability.map(caps.has) ?? true
    }

    /// 页面根视图的辅助功能标识（UI 测试用它判断「到了哪一页」）
    var pageId: String { "page.\(rawValue)" }

    func title(role: Role) -> String {
        switch self {
        case .sell: "卖出"
        case .stockIn: "进货"
        case .reports: "看账"
        case .products: "商品"
        case .settings: role == .cashier ? "设置" : "更多"
        case .records: role == .cashier ? "我记的账" : "记的账"
        case .undoLast: "撤销"
        case .expiry: "快过期的"
        case .count: "盘点"
        case .pairing: "给家里人 / 收银员开通"
        case .devices: "已登录的手机"
        case .deviceName: "这台手机的名字"
        case .scanner: "扫码枪"
        case .account: "账号与密码"
        case .privacy: "隐私政策"
        case .logout: "退出登录"
        }
    }

    /// 还没做的页面在哪一段做（占位页上显示）
    var plannedIn: String? {
        switch self {
        case .sell: "S16"
        case .stockIn: "S19"
        case .reports: "S24"
        case .products: "S25"
        case .records, .undoLast: "S20"
        case .expiry: "S27"
        case .count: "S26"
        case .pairing, .devices: "S23a"
        case .account: "S23b"
        case .scanner: "S14"
        case .privacy: "S21"
        case .logout: "S22b"
        case .settings, .deviceName: nil
        }
    }

    /// 页面颜色：卖出朱红、进货靛青，其余中性
    var mode: ShopMode {
        switch self {
        case .sell: .sell
        case .stockIn: .stock
        default: .neutral
        }
    }
}

/// 根据路由出页面。没有能力的路由一律出「这台手机用不了」页，不出真页面。
struct RouteView: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        Group {
            if !route.isAllowed(model.capabilities) {
                DeniedPage()
            } else {
                switch route {
                case .settings: SettingsView()
                case .deviceName: DeviceNameView()
                default: PlaceholderPage(route: route, role: model.role)
                }
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
    let role: Role

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: route.title(role: role), mode: route.mode, onBack: { dismiss() })
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "hammer")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.mute)
                        .accessibilityHidden(true)
                    Text("这一页还在做")
                        .font(TypeScale.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    if let s = route.plannedIn {
                        Text("开发计划 \(s) 段").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
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
