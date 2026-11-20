import SwiftUI

struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 主按钮（BigButton）。高度、字号固定，不随动态字号变。
struct PrimaryButton: View {
    enum Style { case filled, dark, ghost }
    enum Size {
        case regular, medium, small
        var height: CGFloat {
            switch self {
            case .regular: Tokens.Size.primaryButton
            case .medium: Tokens.Size.primaryButtonMedium
            case .small: Tokens.Size.buttonSmall
            }
        }
        var fontSize: CGFloat {
            switch self {
            case .regular: Tokens.FixedFontSize.primaryButton
            case .medium: 24
            case .small: 22
            }
        }
    }

    let title: String
    var systemImage: String?
    var mode: ShopMode = .sell
    var style: Style = .filled
    var size: Size = .regular
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, mode: ShopMode = .sell,
         style: Style = .filled, size: Size = .regular, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.mode = mode
        self.style = style
        self.size = size
        self.action = action
    }

    private var background: Color {
        switch style {
        case .filled: mode.color
        case .dark: Tokens.Palette.ink
        case .ghost: .clear
        }
    }

    private var foreground: Color { style == .ghost ? Tokens.Palette.ink : .white }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size.fontSize, weight: .bold))
                }
                Text(title)
                    .font(.system(size: size.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
            .overlay {
                if style == .ghost {
                    RoundedRectangle(cornerRadius: Tokens.Radius.button)
                        .strokeBorder(Tokens.Palette.ink, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
    }
}
