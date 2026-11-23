import ShopCore
import SwiftUI
import XCTest
@testable import YuanhuiZhangben

/// 扫码页布局方案（负责人 + Fable 定）：取景框尺寸 / 位置、按钮尺寸，进货页商品卡在时暂停相机识别
@MainActor
final class ScanLayoutTests: XCTestCase {
    /// (名字, 屏幕大小, 安全区上, 安全区下)
    static let phones: [(String, CGSize, CGFloat, CGFloat)] = [
        ("iPhone 17", CGSize(width: 402, height: 874), 62, 34),
        ("iPhone 13", CGSize(width: 390, height: 844), 47, 34),
        ("iPhone SE", CGSize(width: 375, height: 667), 20, 0),
        ("iPhone 17 Pro Max", CGSize(width: 440, height: 956), 62, 34),
    ]

    private func layout(_ screen: CGSize, top: CGFloat, bottom: CGFloat, compact: Bool = false) -> ScanLayout {
        ScanLayout(size: CGSize(width: screen.width, height: screen.height - top - bottom),
                   insets: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0), compact: compact)
    }

    /// 取景框中心在屏幕上的高度（相机区贴着安全区底：顶 = 安全区底 − 相机区高）
    private func finderFrame(_ l: ScanLayout, _ screen: CGSize, bottom: CGFloat) -> CGRect {
        let bandTop = screen.height - bottom - l.bandHeight
        let y = bandTop + ScanLayout.topPadding
        return CGRect(x: (screen.width - l.finder.width) / 2, y: y, width: l.finder.width, height: l.finder.height)
    }

    /// 第 1 条：宽约屏宽 86%（左右各 7%），高约屏高 22–24%，约 2:1；垂直中心在屏高 62–65%
    func testFinderSizeAndPosition() {
        for (name, screen, top, bottom) in Self.phones {
            let l = layout(screen, top: top, bottom: bottom)
            let f = finderFrame(l, screen, bottom: bottom)
            XCTAssertEqual(f.width / screen.width, 0.86, accuracy: 0.005, name)
            XCTAssertEqual(f.minX / screen.width, 0.07, accuracy: 0.005, name)
            XCTAssertTrue((0.22...0.24).contains(f.height / screen.height), "\(name) 高 \(f.height)")
            XCTAssertTrue((0.62...0.65).contains(f.midY / screen.height), "\(name) 中心 \(f.midY / screen.height)")
            XCTAssertEqual(f.width / f.height, 2, accuracy: 0.45, "\(name) 约 2:1")
        }
    }

    /// 第 2 条：两个等宽大按钮在取景框正下方，各约 40% 屏宽、高 ≥ 64pt，底边离安全区 16pt（相机区里按钮靠底）
    func testButtonsUnderTheFinder() {
        for (name, screen, top, bottom) in Self.phones {
            let l = layout(screen, top: top, bottom: bottom)
            XCTAssertGreaterThanOrEqual(ScanLayout.buttonHeight, 64)
            XCTAssertTrue((0.39...0.43).contains(l.buttonWidth / screen.width), "\(name) 按钮宽 \(l.buttonWidth)")
            XCTAssertEqual(l.buttonWidth * 2 + ScanLayout.buttonSpacing, l.finder.width, accuracy: 0.5, "两个按钮左右和取景框齐")
            let f = finderFrame(l, screen, bottom: bottom)
            let buttonsTop = screen.height - bottom - ScanLayout.bottomPadding - ScanLayout.buttonHeight
            XCTAssertGreaterThanOrEqual(buttonsTop - f.maxY, ScanLayout.buttonGap - 0.5, "\(name) 按钮在取景框下面")
        }
    }

    /// 第 3 条：上方内容区（顶栏下沿到取景框上沿）约屏高 35–40%（顶栏 52pt）
    func testContentAreaAboveTheFinder() {
        for (name, screen, top, bottom) in Self.phones where top > 20 {
            let l = layout(screen, top: top, bottom: bottom)
            let f = finderFrame(l, screen, bottom: bottom)
            let content = f.minY - ScanLayout.topPadding - (top + Tokens.Size.modeBar)
            XCTAssertTrue((0.33...0.42).contains(content / screen.height), "\(name) 内容区 \(content / screen.height)")
        }
    }

    /// 第 5 条（可选）：收小时取景框高约屏高 16%，下沿不动
    func testCompactFinderKeepsTheBottomEdge() {
        for (name, screen, top, bottom) in Self.phones {
            let normal = layout(screen, top: top, bottom: bottom)
            let small = layout(screen, top: top, bottom: bottom, compact: true)
            XCTAssertEqual(small.finder.height / screen.height, 0.16, accuracy: 0.005, name)
            XCTAssertEqual(small.finder.width, normal.finder.width)
            XCTAssertEqual(finderFrame(small, screen, bottom: bottom).maxY, finderFrame(normal, screen, bottom: bottom).maxY,
                           accuracy: 1, "\(name) 下沿不动")
        }
    }

    /// 扫码登录页（S21）的取景框样式不变：两个角、4pt；扫码页用四个加粗的角
    func testCornerStyles() {
        XCTAssertEqual(FinderCorners.Style.standard.lineWidth, 4)
        XCTAssertGreaterThan(FinderCorners.Style.bold.lineWidth, FinderCorners.Style.standard.lineWidth)
        let r = CGRect(x: 0, y: 0, width: 300, height: 150)
        func subpaths(_ s: FinderCorners.Style) -> Int {
            var n = 0
            FinderCorners(style: s).path(in: r).forEach { if case .move = $0 { n += 1 } }
            return n
        }
        XCTAssertEqual(subpaths(.standard), 2)
        XCTAssertEqual(subpaths(.bold), 4)
    }

    // MARK: 进货页：商品卡在时暂停相机识别（第 4 条）

    static let colaPack = "6925303770020", erguotou = "6901234500011"

    private func stockModel() throws -> StockInModel {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return StockInModel(db: db, today: try CalendarDate("2026-11-21"),
                            defaults: UserDefaults(suiteName: "ScanLayoutTests-\(UUID().uuidString)")!)
    }

    func testCardPausesCameraScansUntilConfirmedOrCancelled() throws {
        let m = try stockModel()
        XCTAssertEqual(m.handle(Scan(code: Self.colaPack, source: .camera)), .known)
        XCTAssertNil(m.active, "扫到后是商品卡，不出键盘")
        XCTAssertEqual(m.qtyText, "1")
        m.setPackCount(3)
        XCTAssertEqual(m.handle(Scan(code: Self.erguotou, source: .camera)), .ignored, "卡片在：相机来的码不收")
        XCTAssertEqual(m.product?.name, "可口可乐 330ml")
        XCTAssertEqual(m.qtyText, "3", "没记的输入不被换掉")
        // 取消（重新扫）后恢复
        m.clear()
        XCTAssertEqual(m.handle(Scan(code: Self.erguotou, source: .camera)), .known)
        // 确认入库后恢复
        m.fill(cost: "25")
        XCTAssertTrue(m.commit())
        XCTAssertEqual(m.handle(Scan(code: Self.colaPack, source: .camera)), .known)
    }

    func testGunAndManualStillReplaceTheCard() throws {
        let m = try stockModel()
        XCTAssertEqual(m.handle(Scan(code: Self.colaPack, source: .camera)), .known)
        XCTAssertEqual(m.handle(Scan(code: Self.erguotou, source: .gun)), .known)
        XCTAssertEqual(m.qtyLabel, "进了几瓶")
        XCTAssertEqual(m.handle(Scan(code: Self.colaPack, source: .manual)), .known)
        XCTAssertEqual(m.qtyLabel, "进了几箱")
    }

    /// 「－ 数量 ＋」和键盘：点键盘填数量时第一个数字替换步进器上的数；收起回到商品卡
    func testStepperAndKeypadQuantity() throws {
        let m = try stockModel()
        _ = m.handle(Scan(code: Self.colaPack, source: .gun))
        m.setPackCount(4)
        XCTAssertEqual(m.packCount, 4)
        m.focus(.qty)
        m.key(.digit(1)); m.key(.digit(2))
        XCTAssertEqual(m.qtyText, "12", "第一个数字替换原来的 4")
        m.doneEditing()
        XCTAssertNil(m.active)
        m.focus(.qty)
        m.key(.delete)
        XCTAssertEqual(m.qtyText, "", "删除键也是从头填")
        m.setPackCount(0)
        XCTAssertNil(m.packCount)
    }
}
