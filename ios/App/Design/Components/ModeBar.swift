import SwiftUI

/// 顶栏：卖出 = 朱红底白字，进货 = 靛青底白字，中性 = 米纸底墨字。
/// 待传状态：nil = 不显示；0 = 「✓ 已同步」；N = 「↑ N 笔待传」。
/// 返回钮、标题、待传状态在同一个布局里；一行放不下（辅助字号）时，待传状态挪到第二行，标题可换行，不重叠、不截断。
struct ModeBar: View {
    let title: String
    var mode: ShopMode = .neutral
    var pendingCount: Int?
    /// 没网（25e）：待传状态换成「↑ 没网」
    var offline = false
    var onBack: (() -> Void)?

    private var background: Color { mode == .neutral ? Tokens.Palette.paper : mode.color }
    private var foreground: Color { mode == .neutral ? Tokens.Palette.ink : .white }
    private var showsPending: Bool { pendingCount != nil || offline }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneRow
            twoRows
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Tokens.Size.modeBar)
        .foregroundStyle(foreground)
        .background(background.ignoresSafeArea(edges: .top))
    }

    /// 一行：左右两个槽一样宽（各自叠一份对方的隐藏副本），标题居中。
    private var oneRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                back
                pending.hidden().accessibilityHidden(true)
            }
            titleText.lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity)
            ZStack(alignment: .trailing) {
                back.hidden().accessibilityHidden(true)  // 只占位，读屏和 UI 测试都不该看到第二个返回钮
                pending
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 两行：返回 + 标题（可换行）；待传状态单独一行靠右。
    private var twoRows: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                ZStack { back }
                titleText
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                ZStack { back.hidden().accessibilityHidden(true) }
            }
            if showsPending {
                pending.frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 6)
            }
        }
    }

    private var titleText: Text { Text(title).font(TypeScale.nav) }

    @ViewBuilder private var back: some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: Tokens.Size.modeBar, height: Tokens.Size.modeBar)
            }
            .accessibilityLabel("返回")
        } else {
            Color.clear.frame(width: 1, height: Tokens.Size.modeBar)
        }
    }

    @ViewBuilder private var pending: some View {
        if offline {
            Label("没网", systemImage: "arrow.up.to.line")
                .font(TypeScale.secondary)
                .labelStyle(TightLabelStyle())
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
                .accessibilityIdentifier("syncStatus")
        } else if let pendingCount {
            Label(pendingCount > 0 ? "\(pendingCount) 笔待传" : "已同步",
                  systemImage: pendingCount > 0 ? "arrow.up.to.line" : "checkmark")
                .font(TypeScale.secondary)
                .labelStyle(TightLabelStyle())
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
                .accessibilityIdentifier("syncStatus")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// 图标和文字挨得近一点（稿子里「✓ 已同步」之间只有 6pt）
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.fontWeight(.semibold)
            configuration.title
        }
    }
}
