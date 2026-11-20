import SwiftUI
import UIKit
import XCTest
@testable import YuanhuiZhangben

@MainActor
final class TypeScaleTests: XCTestCase {
    /// 验收：大字模式下正文 ≥ 22pt、次要 ≥ 18pt —— 不论系统字号设成多少。
    func testLargeModeBodyAtLeast22AndSecondaryAtLeast18ForEverySystemSize() {
        for system in DynamicTypeSize.allCases {
            let body = TypeScale.pointSize(.body, system: system, largeMode: true)
            let secondary = TypeScale.pointSize(.secondary, system: system, largeMode: true)
            XCTAssertGreaterThanOrEqual(body, 22, "正文 @\(system)")
            XCTAssertGreaterThanOrEqual(secondary, 18, "次要 @\(system)")
        }
    }

    func testLargeModeClampsBetweenXXXLargeAndAccessibility2() {
        XCTAssertEqual(TypeScale.effectiveSize(system: .xSmall, largeMode: true), .xxxLarge)
        XCTAssertEqual(TypeScale.effectiveSize(system: .large, largeMode: true), .xxxLarge)
        XCTAssertEqual(TypeScale.effectiveSize(system: .accessibility1, largeMode: true), .accessibility1)
        XCTAssertEqual(TypeScale.effectiveSize(system: .accessibility5, largeMode: true), .accessibility2)
        XCTAssertEqual(TypeScale.largeModeRange, DynamicTypeSize.xxxLarge ... .accessibility2)
    }

    func testStandardModeFollowsSystem() {
        for system in DynamicTypeSize.allCases {
            XCTAssertEqual(TypeScale.effectiveSize(system: system, largeMode: false), system)
        }
        XCTAssertEqual(TypeScale.pointSize(.body, system: .large, largeMode: false), 17)
        XCTAssertGreaterThan(TypeScale.pointSize(.body, system: .accessibility5, largeMode: false),
                             TypeScale.pointSize(.body, system: .accessibility5, largeMode: true))
    }

    func testNumberFontIsDINAlternateBold() {
        XCTAssertNotNil(UIFont(name: TypeScale.numberFontName, size: 20), "系统里应有 DIN Alternate Bold")
    }
}

@MainActor
final class ComponentTests: XCTestCase {
    private func height<V: View>(_ view: V, size: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return host.sizeThatFits(in: CGSize(width: 350, height: 2000)).height
    }

    /// 验收：主按钮高度 ≥ 60pt，在任何字号下都一样（固定尺寸）。
    func testPrimaryButtonAtLeast60ptAtEverySize() {
        XCTAssertGreaterThanOrEqual(Tokens.Size.primaryButton, 60)
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility2, .accessibility5] {
            let h = height(PrimaryButton("收好钱了，记账", systemImage: "checkmark") {}, size: size)
            XCTAssertGreaterThanOrEqual(h, 60, "主按钮 @\(size)")
            XCTAssertEqual(h, Tokens.Size.primaryButton, accuracy: 0.5, "主按钮高度固定 @\(size)")
        }
    }

    func testPaletteMatchesDesignTokens() {
        let expected: [String: UInt32] = [
            "paper": 0xF3EFE3, "card": 0xFFFDF8, "ink": 0x1F1A17, "ink2": 0x5A5048,
            "line": 0xDDD5C3, "mute": 0xCFC6B4, "sell": 0xC4321C, "sellTint": 0xF7E2DA,
            "stock": 0x1E5A7A, "stockTint": 0xDAE7EE, "tag": 0xF5C83A, "tagTint": 0xFCEFC2,
        ]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: Tokens.Palette.all.map { ($0.id, $0.hex) }), expected)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Tokens.Palette.sell).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 0xC4)
        XCTAssertEqual(Int((g * 255).rounded()), 0x32)
        XCTAssertEqual(Int((b * 255).rounded()), 0x1C)
    }

    func testMoneyFormatsIntegerCents() {
        XCTAssertEqual(Money.yuanString(450), "4.50")
        XCTAssertEqual(Money.yuanString(5350), "53.50")
        XCTAssertEqual(Money.yuanString(0), "0.00")
        XCTAssertEqual(Money.yuanString(-5), "-0.05")
        XCTAssertEqual(Money.yuanString(100_000), "1000.00")
    }

    func testUIFixtureParsing() {
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "gallery"]), .gallery(page: nil))
        XCTAssertEqual(UIFixture.screen(from: ["app", "-uiFixture", "gallery-2"]), .gallery(page: 2))
        XCTAssertNil(UIFixture.screen(from: ["app"]))
        XCTAssertNil(UIFixture.screen(from: ["app", "-uiFixture"]))
        XCTAssertEqual(UIFixture.largeTextOverride(from: ["-uiLargeText", "off"]), false)
        XCTAssertEqual(UIFixture.largeTextOverride(from: ["-uiLargeText", "on"]), true)
        XCTAssertNil(UIFixture.largeTextOverride(from: []))
    }
}
