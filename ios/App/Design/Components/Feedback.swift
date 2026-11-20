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

/// 确认面板：标题 + 几行明细 + 确认 / 取消。
struct ConfirmPanel: View {
    struct Row: Sendable {
        let label: String
        let value: String
    }

    let title: String
    var rows: [Row] = []
    let confirmTitle: String
    var cancelTitle = "再想想"
    var mode: ShopMode = .sell
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline) {
                    Text(rows[i].label).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    Spacer(minLength: 12)
                    Text(rows[i].value).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.trailing)
                }
                Rectangle().fill(Tokens.Palette.line).frame(height: 1)
            }
            PrimaryButton(confirmTitle, systemImage: "checkmark", mode: mode, action: onConfirm)
            PrimaryButton(cancelTitle, style: .ghost, size: .medium, action: onCancel)
        }
    }
}
