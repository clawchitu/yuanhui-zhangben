import SwiftUI
import UIKit
import XCTest
@testable import YuanhuiZhangben

@MainActor
private func fittedSize<V: View>(_ view: V, width: CGFloat = 350) -> CGSize {
    UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 4000))
}

@MainActor
final class TypeScaleTests: XCTestCase {
    /// 验收（计算层）：大字模式下正文 ≥ 22pt、次要 ≥ 18pt —— 不论系统字号设成多少。
    func testLargeModeBodyAtLeast22AndSecondaryAtLeast18ForEverySystemSize() {
        for system in DynamicTypeSize.allCases {
            XCTAssertGreaterThanOrEqual(TypeScale.pointSize(.body, system: system, largeMode: true), 22, "正文 @\(system)")
            XCTAssertGreaterThanOrEqual(TypeScale.pointSize(.secondary, system: system, largeMode: true), 18, "次要 @\(system)")
        }
    }

    func testLargeModeClampsBetweenXXXLargeAndAccessibility2() {
        XCTAssertEqual(TypeScale.effectiveSize(system: .xSmall, largeMode: true), .xxxLarge)
        XCTAssertEqual(TypeScale.effectiveSize(system: .large, largeMode: true), .xxxLarge)
        XCTAssertEqual(TypeScale.effectiveSize(system: .accessibility1, largeMode: true), .accessibility1)
        XCTAssertEqual(TypeScale.effectiveSize(system: .accessibility5, largeMode: true), .accessibility2)
    }

    /// 标准模式跟随系统，但上限同样封在 accessibility2（§14 S11-1）
    func testStandardModeFollowsSystemUpToAccessibility2() {
        for system in DynamicTypeSize.allCases {
            let expected = system > .accessibility2 ? DynamicTypeSize.accessibility2 : system
            XCTAssertEqual(TypeScale.effectiveSize(system: system, largeMode: false), expected, "\(system)")
        }
        XCTAssertEqual(TypeScale.pointSize(.body, system: .large, largeMode: false), 17)
        XCTAssertEqual(TypeScale.pointSize(.body, system: .accessibility5, largeMode: false),
                       TypeScale.pointSize(.body, system: .accessibility2, largeMode: false))
        XCTAssertEqual(TypeScale.standardRange, DynamicTypeSize.xSmall ... .accessibility2)
    }

    func testNumberFontIsDINAlternateBold() {
        XCTAssertNotNil(UIFont(name: TypeScale.numberFontName, size: 20), "系统里应有 DIN Alternate Bold")
    }
}

/// 实际生效链路：AppShell（AppRoot 用的同一个外壳，读设置 → .largeTextMode）+ 组件实际用的 TypeScale 字体，
/// 在系统最小 / 默认 / 最大字号、大字模式开 / 关下，检查环境字号和文字实际渲染尺寸。
@MainActor
final class TypeScaleRenderingTests: XCTestCase {
    private var savedSetting: Any?

    override func setUp() async throws {
        savedSetting = UserDefaults.standard.object(forKey: AppSettings.largeTextModeKey)
    }

    override func tearDown() async throws {
        if let savedSetting {
            UserDefaults.standard.set(savedSetting, forKey: AppSettings.largeTextModeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettings.largeTextModeKey)
        }
    }

    private final class Box { var size: DynamicTypeSize? }

    private struct EnvProbe: View {
        let box: Box
        @Environment(\.dynamicTypeSize) private var size
        var body: some View {
            box.size = size
            return Color.clear.frame(width: 1, height: 1)
        }
    }

    private let sample = "今天卖了十二笔"

    /// 系统字号 = system，大字模式 = largeMode 时，AppShell 里的环境字号。
    private func environmentSize(system: DynamicTypeSize, largeMode: Bool) -> DynamicTypeSize? {
        UserDefaults.standard.set(largeMode, forKey: AppSettings.largeTextModeKey)
        let box = Box()
        _ = fittedSize(AppShell { EnvProbe(box: box) }.environment(\.dynamicTypeSize, system))
        return box.size
    }

    /// AppShell 里用实际字体渲染一行字的高度。
    private func renderedHeight(_ font: Font, system: DynamicTypeSize, largeMode: Bool) -> CGFloat {
        UserDefaults.standard.set(largeMode, forKey: AppSettings.largeTextModeKey)
        return fittedSize(AppShell { Text(sample).font(font).lineLimit(1).fixedSize() }
            .environment(\.dynamicTypeSize, system), width: 2000).height
    }

    /// 固定磅值的参照行高（同一段文字、系统字体）。
    private func referenceHeight(_ points: CGFloat) -> CGFloat {
        fittedSize(Text(sample).font(.system(size: points)).lineLimit(1).fixedSize(), width: 2000).height
    }

    func testShellClampsEnvironmentSize() {
        XCTAssertEqual(environmentSize(system: .xSmall, largeMode: true), .xxxLarge)
        XCTAssertEqual(environmentSize(system: .large, largeMode: true), .xxxLarge)
        XCTAssertEqual(environmentSize(system: .accessibility5, largeMode: true), .accessibility2)
        XCTAssertEqual(environmentSize(system: .xSmall, largeMode: false), .xSmall)
        XCTAssertEqual(environmentSize(system: .large, largeMode: false), .large)
        XCTAssertEqual(environmentSize(system: .accessibility2, largeMode: false), .accessibility2)
        XCTAssertEqual(environmentSize(system: .accessibility3, largeMode: false), .accessibility2, "标准模式也封顶（S11-1）")
        XCTAssertEqual(environmentSize(system: .accessibility5, largeMode: false), .accessibility2, "标准模式也封顶（S11-1）")
    }

    /// 验收：大字模式下正文实际渲染 ≥ 22pt、次要 ≥ 18pt（系统最小 / 默认 / 最大都测）。
    func testLargeModeRendersBodyAtLeast22AndSecondaryAtLeast18() {
        let ref22 = referenceHeight(22), ref18 = referenceHeight(18)
        for system in [DynamicTypeSize.xSmall, .large, .accessibility5] {
            XCTAssertGreaterThanOrEqual(renderedHeight(TypeScale.body, system: system, largeMode: true), ref22, "正文 @\(system)")
            XCTAssertGreaterThanOrEqual(renderedHeight(TypeScale.secondary, system: system, largeMode: true), ref18, "次要 @\(system)")
        }
    }

    /// 系统最大字号、不套外壳时的渲染高度（没有封顶时会有多大）
    private func uncappedHeight(_ font: Font) -> CGFloat {
        fittedSize(Text(sample).font(font).lineLimit(1).fixedSize().environment(\.dynamicTypeSize, .accessibility5), width: 2000).height
    }

    /// 大字模式封顶：系统最大时与 accessibility2 渲染一样大，比不封顶时小。
    func testLargeModeCapsAtAccessibility2() {
        let capped = renderedHeight(TypeScale.body, system: .accessibility5, largeMode: true)
        let ax2 = renderedHeight(TypeScale.body, system: .accessibility2, largeMode: false)
        XCTAssertEqual(capped, ax2, accuracy: 0.5)
        XCTAssertLessThan(capped, uncappedHeight(TypeScale.body))
    }

    /// 验收（S15，§14 S11-1）：标准模式下系统字号调到最大，实际渲染也封顶在 accessibility2。
    func testStandardModeCapsAtAccessibility2WhenRendered() {
        for font in [TypeScale.body, TypeScale.secondary, TypeScale.title, TypeScale.nav] {
            let capped = renderedHeight(font, system: .accessibility5, largeMode: false)
            XCTAssertEqual(capped, renderedHeight(font, system: .accessibility2, largeMode: false), accuracy: 0.5)
            XCTAssertLessThan(capped, uncappedHeight(font))
        }
    }

    /// 关掉大字模式 = 跟随系统：系统默认时正文渲染等于 17pt，系统最小时比 22pt 小。
    func testStandardModeFollowsSystemWhenRendered() {
        XCTAssertEqual(renderedHeight(TypeScale.body, system: .large, largeMode: false), referenceHeight(17), accuracy: 0.5)
        XCTAssertLessThan(renderedHeight(TypeScale.body, system: .xSmall, largeMode: false), referenceHeight(22))
    }
}

@MainActor
final class ComponentTests: XCTestCase {
    /// 验收：主按钮高度 ≥ 60pt —— 所有规格、所有字号下（固定尺寸，不随字号变）。
    func testPrimaryButtonAtLeast60ptForEverySizeAndTypeSize() {
        for spec in PrimaryButton.Size.allCases {
            XCTAssertGreaterThanOrEqual(spec.height, 60)
            for type in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility2, .accessibility5] {
                let h = fittedSize(PrimaryButton("收好钱了，记账", systemImage: "checkmark", size: spec) {}
                    .environment(\.dynamicTypeSize, type)).height
                XCTAssertGreaterThanOrEqual(h, 60, "主按钮 \(spec) @\(type)")
                XCTAssertEqual(h, spec.height, accuracy: 0.5, "主按钮 \(spec) 高度固定 @\(type)")
            }
        }
    }

    /// 顶栏「返回 + 卖出 + 2 笔待传」：默认大字一行；辅助字号下待传挪到第二行（变高），不和标题重叠。
    func testModeBarMovesPendingToSecondLineAtAccessibilitySizes() {
        func height(_ type: DynamicTypeSize, pending: Int?) -> CGFloat {
            fittedSize(ModeBar(title: "卖出", mode: .sell, pendingCount: pending, onBack: {})
                .environment(\.dynamicTypeSize, type)).height
        }
        XCTAssertEqual(height(.xxxLarge, pending: 2), Tokens.Size.modeBar, accuracy: 0.5, "大字默认应一行放下")
        let ax2 = height(.accessibility2, pending: 2)
        XCTAssertGreaterThan(ax2, height(.accessibility2, pending: nil) + 20, "辅助字号下待传应换到第二行")
        // 辅助字号下整条顶栏仍在 350pt 内（没有被内容撑出去叠在一起）
        let ax2Width = fittedSize(ModeBar(title: "卖出", mode: .sell, pendingCount: 2, onBack: {})
            .environment(\.dynamicTypeSize, .accessibility2)).width
        XCTAssertLessThanOrEqual(ax2Width, 350.5)
    }

    /// 实际供组件使用的每个颜色属性，逐项核对 RGBA。
    func testEveryPaletteColorMatchesDesignTokens() {
        let expected: [(String, Color, UInt32)] = [
            ("paper", Tokens.Palette.paper, 0xF3EFE3), ("card", Tokens.Palette.card, 0xFFFDF8),
            ("ink", Tokens.Palette.ink, 0x1F1A17), ("ink2", Tokens.Palette.ink2, 0x5A5048),
            ("line", Tokens.Palette.line, 0xDDD5C3), ("mute", Tokens.Palette.mute, 0xCFC6B4),
            ("sell", Tokens.Palette.sell, 0xC4321C), ("sellTint", Tokens.Palette.sellTint, 0xF7E2DA),
            ("stock", Tokens.Palette.stock, 0x1E5A7A), ("stockTint", Tokens.Palette.stockTint, 0xDAE7EE),
            ("tag", Tokens.Palette.tag, 0xF5C83A), ("tagTint", Tokens.Palette.tagTint, 0xFCEFC2),
        ]
        for (name, color, hex) in expected {
            XCTAssertEqual(rgba(color), hex << 8 | 0xFF, "\(name) 应为 #\(String(hex, radix: 16, uppercase: true))")
        }
        // 陈列页列表就是这些属性本身
        XCTAssertEqual(Tokens.Palette.all.map(\.id), expected.map(\.0))
        for (item, exp) in zip(Tokens.Palette.all, expected) {
            XCTAssertEqual(rgba(item.color), exp.2 << 8 | 0xFF, item.id)
        }
        // 模式色
        XCTAssertEqual(rgba(ShopMode.sell.color), 0xC4321CFF)
        XCTAssertEqual(rgba(ShopMode.stock.color), 0x1E5A7AFF)
    }

    private func rgba(_ color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return c(r) << 24 | c(g) << 16 | c(b) << 8 | c(a)
    }

    func testMoneyFormatsIntegerCents() {
        XCTAssertEqual(Money.yuanString(450), "4.50")
        XCTAssertEqual(Money.yuanString(5350), "53.50")
        XCTAssertEqual(Money.yuanString(0), "0.00")
        XCTAssertEqual(Money.yuanString(-5), "-0.05")
        XCTAssertEqual(Money.yuanString(100_000), "1000.00")
    }

    /// 验收（S15，§14 S11-4）：小号步进器圆钮外观 46pt，点按区域不小于 56pt；圆钮和数字的位置不变。
    func testCompactStepperHitAreaAtLeast56() {
        XCTAssertEqual(QuantityStepper.diameter(compact: true), 46)
        XCTAssertGreaterThanOrEqual(QuantityStepper.hitSize(compact: true), 56)
        XCTAssertGreaterThanOrEqual(QuantityStepper.hitSize(compact: false), 56)
        for type in [DynamicTypeSize.large, .accessibility2] {
            let size = fittedSize(QuantityStepper(value: .constant(4), compact: true).environment(\.dynamicTypeSize, type))
            XCTAssertGreaterThanOrEqual(size.height, 56, "整个步进器（即点按框）高度 @\(type)")
            // 宽 = 两个 56 点按框 + 数字最小宽 44 + 两处间距 5（外观上圆钮边到数字仍是 10）
            XCTAssertEqual(size.width, 56 + 5 + 44 + 5 + 56, accuracy: 0.5)
        }
    }

    func testUIFixtureParsing() {
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "gallery"]), .gallery(page: nil))
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "home"]), .home(unsynced: false))
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "home-unsynced"]), .home(unsynced: true))
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "onboarding"]), .onboarding)
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "settings"]), .settings)
        XCTAssertEqual(UIFixture.role(from: ["-uiFixture", "home"]), .family)
        XCTAssertEqual(UIFixture.role(from: ["-uiRole", "cashier"]), .cashier)
        XCTAssertNil(UIFixture.role(from: ["-uiRole", "revoked"]))
        XCTAssertNil(UIFixture.role(from: ["-uiFixture", "gallery-2"]))
        XCTAssertNil(UIFixture.role(from: []))
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "gallery-5"]), .gallery(page: 5))
        XCTAssertNil(UIFixture.screen(from: ["app"]))
        XCTAssertNil(UIFixture.screen(from: ["app", "-uiFixture"]))
        XCTAssertEqual(UIFixture.largeTextOverride(from: ["-uiLargeText", "off"]), false)
        XCTAssertEqual(UIFixture.largeTextOverride(from: ["-uiLargeText", "on"]), true)
        XCTAssertNil(UIFixture.largeTextOverride(from: []))
    }
}
