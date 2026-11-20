@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import YuanhuiZhangben

/// 相机会话的启停（PR #17 Codex 必须改 4、§14 S14-3 ⑨⑩）：按页面可见性、scene 状态和权限统一决定，
/// 停用之后已经排队的识别回调不再交码；回前台时重新读权限。
@MainActor
final class CameraLifecycleTests: XCTestCase {
    final class FakeRunner: CameraRunning {
        var calls: [String] = []
        var onCode: ((String) -> Void)?
        func start() { calls.append("start") }
        func stop() { calls.append("stop") }
    }

    private var status: AVAuthorizationStatus = .authorized
    private var runner = FakeRunner()
    private var codes: [String] = []

    private func make() -> CameraController {
        let permission = CameraPermission(status: { [unowned self] in status }, requester: { true })
        let c = CameraController(runner: runner, permission: permission)
        c.onCode = { [unowned self] in codes.append($0) }
        return c
    }

    func testStartsOnlyWhenVisibleActiveAndAuthorized() {
        let c = make()
        XCTAssertEqual(runner.calls, [], "建好不开")
        c.update(visible: false, sceneActive: true)
        XCTAssertEqual(runner.calls, [])
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(runner.calls, ["start"])
        XCTAssertTrue(c.running)
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(runner.calls, ["start"], "状态没变不重复开")
    }

    func testBackgroundStopsAndForegroundResumes() {
        let c = make()
        c.update(visible: true, sceneActive: true)
        c.update(visible: true, sceneActive: false)
        XCTAssertEqual(runner.calls, ["start", "stop"], "退到后台（或 inactive）停相机")
        runner.onCode?("6921168509256")
        XCTAssertEqual(codes, [], "后台期间排队的识别回调不交码")
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(runner.calls, ["start", "stop", "start"], "回前台再开")
        runner.onCode?("6921168509256")
        XCTAssertEqual(codes, ["6921168509256"])
    }

    func testPermissionRevokedInBackgroundIsReadOnForegroundAndCameraStaysOff() {
        let c = make()
        c.update(visible: true, sceneActive: true)
        c.update(visible: true, sceneActive: false)
        status = .denied   // 用户在系统设置里关了相机
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(c.permission.access, .denied, "回前台刷新权限")
        XCTAssertEqual(runner.calls, ["start", "stop"], "权限没了不再开")
        runner.onCode?("6921168509256")
        XCTAssertEqual(codes, [])
        // 再到设置里打开，回来就开
        c.update(visible: true, sceneActive: false)
        status = .authorized
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(c.permission.access, .authorized)
        XCTAssertEqual(runner.calls, ["start", "stop", "start"])
    }

    func testPermissionChangeWhileVisibleIsAppliedBySync() {
        status = .notDetermined
        let c = make()
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(runner.calls, [], "还没问过不开")
        status = .authorized
        c.permission.refresh()
        c.sync()
        XCTAssertEqual(runner.calls, ["start"])
    }

    func testLeavingThePageStopsAndNoMoreCodesAreDelivered() {
        let c = make()
        c.update(visible: true, sceneActive: true)
        runner.onCode?("6921168509256")
        c.update(visible: false, sceneActive: true)   // 压到下一页 / 退出页面
        XCTAssertEqual(runner.calls, ["start", "stop"])
        runner.onCode?("6901028075831")
        XCTAssertEqual(codes, ["6921168509256"], "退出页面后不再交码")
    }

    func testPausedByThePageStopsTheCamera() {
        let c = make()
        c.update(visible: true, sceneActive: true)
        c.update(visible: true, sceneActive: true, paused: true)   // 页面被面板盖住
        XCTAssertEqual(runner.calls, ["start", "stop"])
        c.update(visible: true, sceneActive: true, paused: false)
        XCTAssertEqual(runner.calls, ["start", "stop", "start"])
    }

    func testNoCameraOnThisDeviceNeverStarts() {
        let permission = CameraPermission(status: { .authorized }, requester: { true })
        let c = CameraController(runner: nil, permission: permission)
        c.update(visible: true, sceneActive: true)
        XCTAssertFalse(c.running)
    }

    // MARK: 识别范围（§14 S14-2）

    func testRectOfInterestIsClampedToTheUnitSquare() {
        XCTAssertEqual(CameraSession.clampedRectOfInterest(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)),
                       CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3))
        XCTAssertEqual(CameraSession.clampedRectOfInterest(CGRect(x: -0.25, y: 0.25, width: 1.5, height: 0.5)),
                       CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(CameraSession.clampedRectOfInterest(.zero), full, "算不出来时认整个画面（不至于一个码都认不出）")
        XCTAssertEqual(CameraSession.clampedRectOfInterest(.null), full)
        XCTAssertEqual(CameraSession.clampedRectOfInterest(CGRect(x: 3, y: 3, width: 1, height: 1)), full)
        XCTAssertEqual(CameraSession.clampedRectOfInterest(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)), full)
    }

    func testPreviewReportsItsVisibleRectOnLayout() {
        let v = CameraPreviewView(frame: CGRect(x: 0, y: 0, width: 300, height: 112))
        var reported: [CGRect] = []
        v.onVisibleRect = { reported.append($0) }
        v.setNeedsLayout()
        v.layoutIfNeeded()
        XCTAssertEqual(reported.count, 1, "布局后把预览层可见范围（换算成识别坐标）交出去")
        v.layoutIfNeeded()
        XCTAssertEqual(reported.count, 1, "范围没变不重复设")
    }
}
