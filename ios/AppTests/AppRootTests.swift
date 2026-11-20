import XCTest
@testable import YuanhuiZhangben

final class AppRootTests: XCTestCase {
    @MainActor
    func testTitle() {
        XCTAssertEqual(AppRoot.title, "元辉账本")
    }
}
