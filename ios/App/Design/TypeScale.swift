import SwiftUI
import UIKit

/// 动态字号的角色。正文、次要、标题、顶栏标题走系统动态字号。
enum TypeRole: CaseIterable, Sendable {
    case title, nav, body, secondary

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .title: .title2
        case .nav: .headline
        case .body: .body
        case .secondary: .subheadline
        }
    }
}

/// 字号系统。
/// - 大字模式开：把动态字号下限抬到 `xxxLarge`，上限封在 `accessibility2`。
/// - 大字模式关：跟随系统。
/// - 价格、总价、主按钮、键盘、步进器是固定尺寸（`number(_:)` / `Tokens.FixedFontSize`），不走这套。
enum TypeScale {
    static let largeModeFloor: DynamicTypeSize = .xxxLarge
    static let largeModeCeiling: DynamicTypeSize = .accessibility2
    static let largeModeRange: ClosedRange<DynamicTypeSize> = largeModeFloor...largeModeCeiling
    static let fullRange: ClosedRange<DynamicTypeSize> = .xSmall ... .accessibility5

    static let title = Font.title2.weight(.semibold)
    static let nav = Font.headline
    static let body = Font.body
    static let secondary = Font.subheadline

    /// 数字字体：DIN Alternate Bold，固定尺寸。
    static let numberFontName = "DINAlternate-Bold"
    static func number(_ size: CGFloat) -> Font {
        .custom(numberFontName, fixedSize: size).monospacedDigit()
    }

    static let price = number(Tokens.FixedFontSize.price)
    static let total = number(Tokens.FixedFontSize.total)
    static let key = number(Tokens.FixedFontSize.key)
    static let primaryButton = Font.system(size: Tokens.FixedFontSize.primaryButton, weight: .semibold)

    static func effectiveSize(system: DynamicTypeSize, largeMode: Bool) -> DynamicTypeSize {
        guard largeMode else { return system }
        return min(max(system, largeModeFloor), largeModeCeiling)
    }

    /// 某个角色在给定系统字号、大字模式下的实际磅值。
    static func pointSize(_ role: TypeRole, system: DynamicTypeSize, largeMode: Bool) -> CGFloat {
        let size = effectiveSize(system: system, largeMode: largeMode)
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: role.uiTextStyle, compatibleWith: traits).pointSize
    }

    static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

extension View {
    /// 在根视图上套一次。开 = 动态字号夹在 xxxLarge…accessibility2；关 = 跟随系统。
    func largeTextMode(_ enabled: Bool) -> some View {
        dynamicTypeSize(enabled ? TypeScale.largeModeRange : TypeScale.fullRange)
    }
}
