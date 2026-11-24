import SwiftUI

/// 数字键盘。按键尺寸、数字字号固定。
struct Keypad: View {
    enum Key: Hashable, Sendable {
        case digit(Int), dot, delete
    }

    var showsDot = true
    /// 键高、行距：默认 56 / 8；小屏放不下名称时 04a 会压矮（最低 44，见 PR #43 Fable 决定）
    var keyHeight: CGFloat = Tokens.Size.key
    var spacing: CGFloat = 8
    let onKey: (Key) -> Void

    /// 四行键加三道行距的总高
    static func height(key: CGFloat, spacing: CGFloat) -> CGFloat { 4 * key + 3 * spacing }

    private var rows: [[Key?]] {
        [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [showsDot ? .dot : nil, .digit(0), .delete],
        ]
    }

    var body: some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<4, id: \.self) { r in
                GridRow {
                    ForEach(0..<3, id: \.self) { c in
                        keyView(rows[r][c])
                    }
                }
            }
        }
    }

    @ViewBuilder private func keyView(_ key: Key?) -> some View {
        if let key {
            Button { onKey(key) } label: {
                label(for: key)
                    .foregroundStyle(Tokens.Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.key))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.key).strokeBorder(Tokens.Palette.line, lineWidth: 1))
            }
            .buttonStyle(PressDimStyle())
            .accessibilityLabel(accessibilityLabel(for: key))
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: keyHeight)
        }
    }

    @ViewBuilder private func label(for key: Key) -> some View {
        switch key {
        case .digit(let n): Text("\(n)").font(TypeScale.key)
        case .dot: Text(".").font(TypeScale.key)
        case .delete: Image(systemName: "delete.left").font(.system(size: 26, weight: .semibold))
        }
    }

    private func accessibilityLabel(for key: Key) -> String {
        switch key {
        case .digit(let n): "\(n)"
        case .dot: "点"
        case .delete: "删除"
        }
    }
}
