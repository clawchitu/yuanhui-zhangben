import SwiftUI

/// 步进器（买几个 / 进几个）。圆钮和数字尺寸固定。
struct QuantityStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...9999
    var compact = false

    private var diameter: CGFloat { compact ? Tokens.Size.stepperCompact : Tokens.Size.stepper }

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            circle("minus", enabled: value > range.lowerBound) { value -= 1 }
            Text("\(value)")
                .font(TypeScale.number(compact ? Tokens.FixedFontSize.stepperCompact : Tokens.FixedFontSize.stepper))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(minWidth: compact ? 44 : 60)
            circle("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("数量")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value += 1 }
            case .decrement: if value > range.lowerBound { value -= 1 }
            @unknown default: break
            }
        }
    }

    private func circle(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 20 : 24, weight: .bold))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Tokens.Palette.card))
                .overlay(Circle().strokeBorder(Tokens.Palette.ink, lineWidth: 2))
        }
        .buttonStyle(PressDimStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
