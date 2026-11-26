import SwiftUI

/// 横幅：提醒 = 价签黄；柔和 = 价签黄浅；已过期 = 墨底白字。
struct Banner: View {
    enum Kind { case alert, soft, expired }

    let kind: Kind
    let text: String
    var systemImage: String? = "bell.fill"

    private var background: Color {
        switch kind {
        case .alert: Tokens.Palette.tag
        case .soft: Tokens.Palette.tagTint
        case .expired: Tokens.Palette.ink
        }
    }

    private var foreground: Color { kind == .expired ? .white : Tokens.Palette.ink }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(TypeScale.body.weight(kind == .soft ? .medium : .semibold))
        .foregroundStyle(foreground)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
    }
}

/// 小标签：黄 = 刚扫到/提醒；墨 = 已过期；描边 = 普通说明。
struct Pill: View {
    enum Kind { case tag, ink, outline }

    let text: String
    var kind: Kind = .tag

    var body: some View {
        Text(text)
            .font(TypeScale.secondary.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .foregroundStyle(kind == .ink ? Color.white : Tokens.Palette.ink)
            .background {
                switch kind {
                case .tag: RoundedRectangle(cornerRadius: Tokens.Radius.pill).fill(Tokens.Palette.tag)
                case .ink: RoundedRectangle(cornerRadius: Tokens.Radius.pill).fill(Tokens.Palette.ink)
                case .outline: RoundedRectangle(cornerRadius: Tokens.Radius.pill).strokeBorder(Tokens.Palette.ink, lineWidth: 1.5)
                }
            }
    }
}

/// 底部抽屉的外观（白卡、上圆角、把手）。弹出逻辑由调用方决定。
struct BottomSheet<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Tokens.Palette.mute).frame(width: 44, height: 5)
            content
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.card,
                    in: UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.sheet, topTrailingRadius: Tokens.Radius.sheet))
        .shadow(color: .black.opacity(0.12), radius: 12, y: -2)
    }
}

/// 确认面板（26 通用确认面板）：标题 + 说明 / 几行明细 + 确认 / 取消。
struct ConfirmPanel: View {
    struct Row: Sendable {
        let label: String
        let value: String
    }

    let title: String
    /// 标题下面的一段说明（26：「退出后它要重新扫码才能用。还没传上去的账会先传完。」）
    var message: String?
    var rows: [Row] = []
    let confirmTitle: String
    var cancelTitle = "再想想"
    var mode: ShopMode = .sell
    /// 确认按钮：默认按页面颜色实心带勾；26 的危险操作用黑底不带图标
    var confirmStyle: PrimaryButton.Style = .filled
    var confirmImage: String? = "checkmark"
    var confirmId = "confirm.ok"
    var cancelId = "confirm.cancel"
    /// 确认后在办（按钮变灰，防连点）
    var busy = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("confirm.title")
            if let message {
                Text(message)
                    .font(TypeScale.body)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline) {
                    Text(rows[i].label).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    Spacer(minLength: 12)
                    Text(rows[i].value).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.trailing)
                }
                Rectangle().fill(Tokens.Palette.line).frame(height: 1)
            }
            PrimaryButton(confirmTitle, systemImage: confirmImage, mode: mode, style: confirmStyle, action: onConfirm)
                .disabled(busy)
                .accessibilityIdentifier(confirmId)
            PrimaryButton(cancelTitle, style: .ghost, size: .medium, action: onCancel)
                .accessibilityIdentifier(cancelId)
        }
    }
}

/// 26 通用确认面板以底部抽屉弹出：`item` 非空时弹，关掉（下拉、点取消）时置空。大字时可以滚动
struct ConfirmSheetModifier<Item: Identifiable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let panel: (Item) -> Panel
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.sheet(item: $item) { it in
            ScrollView {
                VStack(spacing: 14) {
                    Capsule().fill(Tokens.Palette.mute).frame(width: 44, height: 5)
                    panel(it)
                }
                .padding(.top, 12)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Tokens.Palette.card)
            .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationCornerRadius(Tokens.Radius.sheet)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("confirm.sheet")
        }
    }
}

extension View {
    func confirmSheet<Item: Identifiable, Panel: View>(item: Binding<Item?>, @ViewBuilder panel: @escaping (Item) -> Panel) -> some View {
        modifier(ConfirmSheetModifier(item: item, panel: panel))
    }
}
