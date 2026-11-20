import ShopCore
import SwiftUI

/// 16 / 16b：登录后第一次进来，选字的大小（默认选中大字），家用手机顺带起名字；收银员不起名（16b），
/// 只显示开通时家里人起的称呼。选择存在本机，以后在设置里能改。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.systemTypeSize) private var systemSize
    @AppStorage(AppSettings.largeTextModeKey) private var storedLargeText = true

    @State private var largeText: Bool?
    @State private var name: String?
    @State private var error: String?

    private var selectedLarge: Bool { largeText ?? storedLargeText }
    private var canName: Bool { model.capabilities.has(.renameDevice) }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: "这台手机")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("登录好了！选一下字的大小")
                        .font(TypeScale.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("以后在设置里能改，只管这台手机")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    VStack(spacing: 14) {
                        FontOption(title: "大字（推荐）", large: true, selected: selectedLarge,
                                   caption: caption, system: systemSize) { largeText = true }
                            .accessibilityIdentifier("onboarding.large")
                        FontOption(title: "标准", large: false, selected: !selectedLarge,
                                   caption: caption, system: systemSize) { largeText = false }
                            .accessibilityIdentifier("onboarding.standard")
                    }
                    .padding(.top, 16)
                    if canName {
                        Text("给这台手机起个名字")
                            .font(TypeScale.body.weight(.bold))
                            .foregroundStyle(Tokens.Palette.ink)
                            .padding(.top, 22)
                            .accessibilityIdentifier("onboarding.nameTitle")
                        DeviceNamePicker(selection: nameBinding)
                            .padding(.top, 12)
                    } else {
                        CashierDeviceCard(name: model.session.deviceLabel)
                            .padding(.top, 18)
                    }
                    if let error {
                        Text(error).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell).padding(.top, 10)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            PrimaryButton("好了，开始用", mode: .neutral, style: .dark) { done() }
                .accessibilityIdentifier("onboarding.done")
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.onboarding")
    }

    /// 样例商品下面那行：能看库存的手机写「还剩 126 罐」，收银员写「刚扫的 · 单价」（收银员看不到库存，§14 S12-3）
    private var caption: String {
        DataVisibility.seesStock(model.role) ? "还剩 126 罐" : "刚扫的 · 单价"
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name ?? DeviceNamePicker.initialSelection(current: model.session.deviceLabel) },
                set: { name = $0 })
    }

    private func done() {
        do {
            try model.finishOnboarding(largeText: selectedLarge, deviceName: canName ? nameBinding.wrappedValue : nil)
        } catch {
            self.error = "没存上：\(error.localizedDescription)"
        }
    }
}

/// 16 的字号选项卡片：标题 + 圆形勾 + 一行样例商品（按这一档的字号显示，不随当前设置变）。
private struct FontOption: View {
    let title: String
    let large: Bool
    let selected: Bool
    let caption: String
    let system: DynamicTypeSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(TypeScale.body.weight(.bold))
                    Spacer(minLength: 8)
                    check
                }
                .padding(.bottom, 12)
                Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
                sample
                    .previewTypeMode(largeMode: large, system: system)
                    .padding(.top, 14)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22)
                .strokeBorder(selected ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: selected ? 4 : 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(selected ? "已选" : "没选")
    }

    @ViewBuilder private var check: some View {
        if selected {
            Circle().fill(Tokens.Palette.ink).frame(width: 34, height: 34)
                .overlay(Image(systemName: "checkmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white))
        } else {
            Circle().strokeBorder(Tokens.Palette.mute, lineWidth: 2.5).frame(width: 34, height: 34)
        }
    }

    private var sample: some View {
        HStack(alignment: .center, spacing: 12) {
            CanIcon(size: large ? 48 : 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("可口可乐 330ml").font(TypeScale.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            PriceText(cents: 300, size: large ? 28 : 23)
        }
    }
}

/// 样例商品的小图（一罐可乐）。只在 16 上做示意。
private struct CanIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16).fill(Color(hex: 0xECE4D3))
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: size * 0.04).fill(Color(hex: 0x8C857B))
                    .frame(width: size * 0.36, height: size * 0.08)
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.07).fill(Color(hex: 0xC8463A))
                    Rectangle().fill(Color(hex: 0xF4DCD3)).frame(height: size * 0.09).offset(y: -size * 0.06)
                }
                .frame(width: size * 0.4, height: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 16b / 21b 上的收银员手机卡片：称呼是开通时家里人起的，这里不能改。
struct CashierDeviceCard: View {
    let name: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "iphone")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                Text("收银员 · 名字是开通时起的").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.cashierDevice")
    }
}

/// 起名字：三个常用名 + 「自己填…」（系统键盘）。16 和「这台手机的名字」共用。
struct DeviceNamePicker: View {
    static let presets = ["柜台手机", "爸爸的手机", "妈妈的手机"]

    /// 第一次进来：本机现在的名字是常用名就选它，否则默认「柜台手机」（稿子 16）
    static func initialSelection(current: String) -> String {
        presets.contains(current) ? current : presets[0]
    }

    @Binding var selection: String
    @State private var typing = false
    @State private var draft = ""

    private var names: [String] {
        Self.presets.contains(selection) || selection.isEmpty ? Self.presets : Self.presets + [selection]
    }

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(names, id: \.self) { n in
                chip(n, selected: n == selection) { selection = n }
            }
            chip("自己填…", selected: false) {
                draft = Self.presets.contains(selection) ? "" : selection
                typing = true
            }
            .accessibilityIdentifier("name.custom")
        }
        .alert("给这台手机起个名字", isPresented: $typing) {
            TextField("比如：小卖部手机", text: $draft)
            Button("不填了", role: .cancel) {}
            Button("好了") {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { selection = String(t.unicodeScalars.prefix(LocalDB.deviceLabelMaxLength).map(Character.init)) }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TypeScale.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? .white : Tokens.Palette.ink)
                .padding(.horizontal, 18)
                .frame(minHeight: Tokens.Size.minHitTarget - 6)
                .background(Capsule().fill(selected ? Tokens.Palette.ink : Tokens.Palette.card))
                .overlay(Capsule().strokeBorder(selected ? Tokens.Palette.ink : Tokens.Palette.line, lineWidth: 2.5))
                .contentShape(Capsule())
                .padding(.vertical, 3)
        }
        .buttonStyle(PressDimStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("name.\(title)")
    }
}

/// 从左到右排，一行放不下就换行（名字小块用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let w = rows.map(\.width).max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (i, size) in zip(row.indices, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            var size = subviews[i].sizeThatFits(.unspecified)
            if size.width > width {  // 一块比一整行还宽（很长的自定义名字）：按整行宽度换行排
                size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let needed = cur.indices.isEmpty ? size.width : cur.width + spacing + size.width
            if !cur.indices.isEmpty && needed > width {
                rows.append(cur)
                cur = Row()
            }
            cur.width = cur.indices.isEmpty ? size.width : cur.width + spacing + size.width
            cur.indices.append(i)
            cur.sizes.append(size)
            cur.height = max(cur.height, size.height)
        }
        if !cur.indices.isEmpty { rows.append(cur) }
        return rows
    }
}
