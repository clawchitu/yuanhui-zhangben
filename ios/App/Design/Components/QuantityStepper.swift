import SwiftUI

/// 步进器（买几个 / 进几个）。圆钮和数字尺寸固定。
/// 小号圆钮外观照稿子是 46pt，但点按区域扩到 56pt（§14 S11-4）：圆钮居中放在 56pt 的点按框里，
/// 框和数字之间的间距相应减掉 (56 − 46) / 2 × 2，所以圆钮和数字的位置与稿子一样。
struct QuantityStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...9999
    var compact = false

    /// 圆钮的外观直径
    static func diameter(compact: Bool) -> CGFloat { compact ? Tokens.Size.stepperCompact : Tokens.Size.stepper }
    /// 圆钮的点按区域边长：不小于 56pt（固定尺寸控件的点按下限）
    static func hitSize(compact: Bool) -> CGFloat { max(diameter(compact: compact), Tokens.Size.minHitTarget) }
    /// 圆钮外观边缘到数字的间距（稿子：小号 10，大号 14）
    private static func visualSpacing(compact: Bool) -> CGFloat { compact ? 10 : 14 }

    private var diameter: CGFloat { Self.diameter(compact: compact) }
    private var hitSize: CGFloat { Self.hitSize(compact: compact) }

    var body: some View {
        HStack(spacing: max(0, Self.visualSpacing(compact: compact) - (hitSize - diameter) / 2)) {
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
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
