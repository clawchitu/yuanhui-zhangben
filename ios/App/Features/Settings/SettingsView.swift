import ShopCore
import SwiftUI

/// 设置：家用 = 21a「更多」，收银员 = 21b「设置」（恰好五项：大字模式、扫码枪、隐私政策、退出登录、版本）。
/// 每一行都按能力表出；进了没能力的路由也只会看到「用不了」页（RouteView）。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.largeTextModeKey) private var largeText = true

    private var caps: Capabilities { model.capabilities }
    private var cashier: Bool { model.layout == .cashier }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.settings.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            ScrollView {
                VStack(spacing: 12) {
                    if cashier { cashierBody } else { familyBody }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.settings.pageId)
    }

    // MARK: 21a

    @ViewBuilder private var familyBody: some View {
        let f = model.figures
        SettingsCard {
            largeTextRow(subtitle: "字更大，看得更清楚")
            if caps.has(.renameDevice) {
                RowDivider()
                SettingsLink(.deviceName, title: "这台手机的名字", value: model.session.deviceLabel)
            }
        }
        let stockRows: [Route] = [.expiry, .count].filter { $0.isAllowed(caps) }
        if !stockRows.isEmpty {
            SettingsCard {
                if Route.expiry.isAllowed(caps) {
                    SettingsLink(.expiry, title: "快过期的") {
                        if f.expiringCount > 0 { Pill(text: "\(f.expiringCount) 样") }
                    }
                }
                if stockRows.count == 2 { RowDivider() }
                if Route.count.isAllowed(caps) {
                    SettingsLink(.count, title: "盘点", value: f.countSummary)
                }
            }
        }
        SettingsCard {
            if caps.has(.pairing) {
                SettingsLink(.pairing, title: "给家里人 / 收银员开通")
                RowDivider()
            }
            if caps.has(.manageDevices) {
                SettingsLink(.devices, title: "已登录的手机", value: f.deviceCount.map { "\($0) 台" })
                RowDivider()
            }
            scannerRow
        }
        SettingsCard {
            if caps.has(.account) {
                SettingsLink(.account, title: "账号与密码", value: "改密码、注销")
                RowDivider()
            }
            SettingsLink(.privacy, title: "隐私政策")
        }
        SettingsCard {
            SettingsLink(.logout, title: "退出登录")
        }
        Text("元辉账本 版本 \(Self.version)")
            .font(TypeScale.secondary)
            .foregroundStyle(Tokens.Palette.ink2)
            .padding(.top, 4)
            .accessibilityIdentifier("settings.versionFooter")
    }

    // MARK: 21b

    @ViewBuilder private var cashierBody: some View {
        HStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.session.deviceLabel).font(TypeScale.body.weight(.bold))
                Text("收银员 · \(model.session.storeName)").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.deviceHeader")
        SettingsCard {
            largeTextRow(subtitle: "字更大，看得更清楚")
            RowDivider()
            scannerRow
            RowDivider()
            SettingsLink(.privacy, title: "隐私政策")
        }
        SettingsCard {
            SettingsLink(.logout, title: "退出登录")
            RowDivider()
            HStack {
                Text("版本").font(TypeScale.body)
                Spacer(minLength: 12)
                Text(Self.version).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: Tokens.Size.minHitTarget)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.item.version")
        }
        Text("退出以后，要让家里人重新出码才能再用。")
            .font(TypeScale.secondary)
            .foregroundStyle(Tokens.Palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    // MARK: 共用行

    private func largeTextRow(subtitle: String) -> some View {
        Toggle(isOn: $largeText) {
            VStack(alignment: .leading, spacing: 2) {
                Text("大字模式").font(TypeScale.body.weight(.bold))
                Text(subtitle).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Tokens.Palette.ink)
        }
        .tint(Tokens.Palette.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: Tokens.Size.minHitTarget)
        .accessibilityIdentifier("settings.item.largeText")
    }

    private var scannerRow: some View {
        SettingsLink(.scanner, title: "扫码枪", value: model.scannerConnected ? "已连上" : "没连")
    }
}

/// 白卡分组
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Tokens.Palette.line).frame(height: 1.5).padding(.horizontal, 16)
    }
}

/// 一行入口：标题、右侧小字或小标签、箭头。辅助字号下右侧挪到标题下面，不截断。
struct SettingsLink<Accessory: View>: View {
    let route: Route
    let title: String
    let value: String?
    let accessory: Accessory

    init(_ route: Route, title: String, value: String? = nil) where Accessory == EmptyView {
        self.init(route, title: title, value: value) { EmptyView() }
    }

    init(_ route: Route, title: String, value: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.route = route
        self.title = title
        self.value = value
        self.accessory = accessory()
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        titleText.fixedSize()
                        Spacer(minLength: 0)
                        trailing.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        titleText.fixedSize(horizontal: false, vertical: true)
                        trailing
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.ink2)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: Tokens.Size.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("settings.item.\(route.rawValue)")
    }

    private var titleText: some View {
        Text(title).font(TypeScale.body).multilineTextAlignment(.leading)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            accessory
            if let value {
                Text(value).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            }
        }
    }
}

/// 21a「这台手机的名字」：和 16 一样的起名小块，存好回到「更多」。只改本机记录，报给服务器在 S21 接。
struct DeviceNameView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.deviceName.title(model.layout), onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("家里人看「记的账」时，会看到是哪台手机记的。")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    DeviceNamePicker(selection: binding)
                    if let error {
                        Text(error).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            PrimaryButton("存好", mode: .neutral, style: .dark) {
                do {
                    try model.rename(binding.wrappedValue)
                    dismiss()
                } catch {
                    self.error = "没存上：\(error.localizedDescription)"
                }
            }
            .accessibilityIdentifier("deviceName.save")
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.deviceName.pageId)
    }

    private var binding: Binding<String> {
        Binding(get: { name ?? model.session.deviceLabel }, set: { name = $0 })
    }
}
