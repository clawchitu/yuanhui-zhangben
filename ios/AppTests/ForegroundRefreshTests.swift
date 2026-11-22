import SwiftUI
import XCTest
@testable import YuanhuiZhangben

/// PR #35 Fable 可选 1：回到前台必须再取 `/v1/config`、补报手机名。系统实际给的序列是 background → inactive → active。
final class ForegroundRefreshTests: XCTestCase {
    private func feed(_ phases: [ScenePhase]) -> [Bool] {
        var f = ForegroundRefresh()
        return phases.map { f.shouldRefresh(on: $0) }
    }

    func testBackgroundInactiveActiveTriggersOnce() {
        XCTAssertEqual(feed([.active, .inactive, .background, .inactive, .active]), [false, false, false, false, true])
    }

    func testEveryReturnTriggers() {
        let one: [ScenePhase] = [.inactive, .background, .inactive, .active]
        XCTAssertEqual(feed([.active] + one + one + one).filter { $0 }.count, 3)
    }

    func testDirectBackgroundToActiveAlsoTriggers() {
        XCTAssertEqual(feed([.active, .background, .active]), [false, false, true])
    }

    /// 只是 inactive（下拉通知中心、来电提示）不算回前台；第一次 active（冷启动，由 .task 取）也不算
    func testInactiveOnlyDoesNotTrigger() {
        XCTAssertEqual(feed([.active, .inactive, .active, .inactive, .active]), [false, false, false, false, false])
    }

    /// 回前台触发一次后标记清掉：再来一次 inactive → active 不重复取
    func testFlagResetsAfterTrigger() {
        XCTAssertEqual(feed([.background, .inactive, .active, .inactive, .active]), [false, false, true, false, false])
    }
}
