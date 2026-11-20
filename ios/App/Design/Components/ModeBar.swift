import SwiftUI

/// 顶栏：卖出 = 朱红底白字，进货 = 靛青底白字，中性 = 米纸底墨字。
struct ModeBar: View {
    let title: String
    var mode: ShopMode = .neutral
    var pendingCount: Int?
    var onBack: (() -> Void)?

    private var background: Color { mode == .neutral ? Tokens.Palette.paper : mode.color }
    private var foreground: Color { mode == .neutral ? Tokens.Palette.ink : .white }

    var body: some View {
        ZStack {
            Text(title)
                .font(TypeScale.nav)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 64)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: Tokens.Size.modeBar, height: Tokens.Size.modeBar)
                    }
                    .accessibilityLabel("返回")
                }
                Spacer()
                if let pendingCount, pendingCount > 0 {
                    Label("\(pendingCount) 笔待传", systemImage: "arrow.up.to.line")
                        .font(TypeScale.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Size.modeBar)
        .foregroundStyle(foreground)
        .background(background.ignoresSafeArea(edges: .top))
    }
}
