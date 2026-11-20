import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 设计令牌。值来自设计稿 base.css，改这里之前先改设计稿。
enum Tokens {
    /// 陈列页和测试用的命名列表。颜色只有一个来源：下面 `Palette` 里的静态属性。
    struct NamedColor: Identifiable {
        let id: String
        let label: String
        let color: Color
    }

    enum Palette {
        static let paper = Color(hex: 0xF3EFE3)
        static let card = Color(hex: 0xFFFDF8)
        static let ink = Color(hex: 0x1F1A17)
        static let ink2 = Color(hex: 0x5A5048)
        static let line = Color(hex: 0xDDD5C3)
        static let mute = Color(hex: 0xCFC6B4)
        /// 卖出
        static let sell = Color(hex: 0xC4321C)
        static let sellTint = Color(hex: 0xF7E2DA)
        /// 进货
        static let stock = Color(hex: 0x1E5A7A)
        static let stockTint = Color(hex: 0xDAE7EE)
        /// 刚扫到、提醒
        static let tag = Color(hex: 0xF5C83A)
        static let tagTint = Color(hex: 0xFCEFC2)

        static var all: [NamedColor] {
            [
                .init(id: "paper", label: "米纸", color: paper),
                .init(id: "card", label: "白卡", color: card),
                .init(id: "ink", label: "墨", color: ink),
                .init(id: "ink2", label: "淡墨", color: ink2),
                .init(id: "line", label: "线", color: line),
                .init(id: "mute", label: "灰", color: mute),
                .init(id: "sell", label: "朱红·卖出", color: sell),
                .init(id: "sellTint", label: "朱红浅", color: sellTint),
                .init(id: "stock", label: "靛青·进货", color: stock),
                .init(id: "stockTint", label: "靛青浅", color: stockTint),
                .init(id: "tag", label: "价签黄", color: tag),
                .init(id: "tagTint", label: "价签黄浅", color: tagTint),
            ]
        }
    }

    /// 固定尺寸（不随动态字号变化）。
    enum Size {
        static let primaryButton: CGFloat = 72
        static let primaryButtonMedium: CGFloat = 64
        static let buttonSmall: CGFloat = 60
        static let key: CGFloat = 56
        static let stepper: CGFloat = 56
        static let stepperCompact: CGFloat = 46
        static let thumb: CGFloat = 64
        static let modeBar: CGFloat = 52
    }

    enum Radius {
        static let card: CGFloat = 18
        static let button: CGFloat = 18
        static let banner: CGFloat = 16
        static let key: CGFloat = 12
        static let pill: CGFloat = 8
        static let sheet: CGFloat = 26
    }

    /// 固定字号：价格、总价、主按钮、键盘、步进器不走动态字号。
    enum FixedFontSize {
        static let price: CGFloat = 48
        static let total: CGFloat = 60
        static let primaryButton: CGFloat = 26
        static let key: CGFloat = 30
        static let stepper: CGFloat = 34
        static let stepperCompact: CGFloat = 28
    }
}

/// 卖出 / 进货 / 中性。决定顶栏和主按钮的颜色。
enum ShopMode: Sendable {
    case neutral, sell, stock

    var color: Color {
        switch self {
        case .neutral: Tokens.Palette.ink
        case .sell: Tokens.Palette.sell
        case .stock: Tokens.Palette.stock
        }
    }

    var tint: Color {
        switch self {
        case .neutral: Tokens.Palette.line
        case .sell: Tokens.Palette.sellTint
        case .stock: Tokens.Palette.stockTint
        }
    }
}
