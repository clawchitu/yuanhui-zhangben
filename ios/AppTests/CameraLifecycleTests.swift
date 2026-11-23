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
        var onFrame: (([CameraCode]) -> Void)?
        func start() { calls.append("start") }
        func stop() { calls.append("stop") }
    }

    private var status: AVAuthorizationStatus = .authorized
    private var runner = FakeRunner()
    private var codes: [String] = []

    private func make() -> CameraController {
        let permission = CameraPermission(status: { [unowned self] in status }, requester: { true })
        let c = CameraController(runner: runner, permission: permission)
        c.onFrame = { [unowned self] in codes += $0.map(\.value) }
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
        runner.onFrame?([CameraCode("6921168509256", kind: .ean13)])
        XCTAssertEqual(codes, [], "后台期间排队的识别回调不交码")
        c.update(visible: true, sceneActive: true)
        XCTAssertEqual(runner.calls, ["start", "stop", "start"], "回前台再开")
        runner.onFrame?([CameraCode("6921168509256", kind: .ean13)])
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
        runner.onFrame?([CameraCode("6921168509256", kind: .ean13)])
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
        runner.onFrame?([CameraCode("6921168509256", kind: .ean13)])
        c.update(visible: false, sceneActive: true)   // 压到下一页 / 退出页面
        XCTAssertEqual(runner.calls, ["start", "stop"])
        runner.onFrame?([CameraCode("6901028075831", kind: .ean13)])
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

    // MARK: 代际隔离（PR #17 Codex 第二轮 1）

    final class FakeOutput: MetadataOutputTarget {
        var rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        private(set) var relay: CameraSession.Relay?
        private(set) var installs = 0
        func setMetadataObjectsDelegate(_ objectsDelegate: (any AVCaptureMetadataOutputObjectsDelegate)?,
                                        queue objectsCallbackQueue: DispatchQueue?) {
            relay = objectsDelegate as? CameraSession.Relay
            if relay != nil { installs += 1 }
        }
    }

    private let visible = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75)

    private func makeSession(_ out: FakeOutput) -> CameraSession {
        let s = CameraSession(testOutput: out)
        s.onFrame = { [unowned self] in codes += $0.map(\.value) }
        return s
    }

    /// 等会话队列做完已排的活，再让主线程上已排的块跑完（「开交码」在那里）
    private func flush(_ s: CameraSession) {
        s.waitForQueue()
        let e = expectation(description: "main")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    func testQueuedCallbackFromTheOldSessionIsDroppedAfterAQuickStopAndRestart() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let old = try! XCTUnwrap(out.relay)
        old.deliver(["6921168509256"])
        XCTAssertEqual(codes, ["6921168509256"], "这一代的码照常交")
        // 旧会话的回调已经排在主线程上；这时快速停用再启用（会话队列还没来得及做完停止）
        s.stop()
        s.start()
        old.deliver(["6901028075831"])
        XCTAssertEqual(codes, ["6921168509256"], "重启后、新回调装好前，旧会话排队的码丢掉")
        flush(s)
        old.deliver(["6901028075831"])
        XCTAssertEqual(codes, ["6921168509256"], "新一代装好之后，旧会话排队的码还是丢掉")
        let new = try! XCTUnwrap(out.relay)
        XCTAssertNotEqual(new.epoch, old.epoch)
        new.deliver(["6954767412345"])
        XCTAssertEqual(codes, ["6921168509256", "6954767412345"], "新一代的码照常交")
    }

    func testOldCallbackQueuedBeforeStopRunsAfterRestartAndIsDropped() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let old = try! XCTUnwrap(out.relay)
        // 交错：旧回调先排上主队列，然后停、启，旧回调在重启之后才执行
        let done = expectation(description: "old")
        DispatchQueue.main.async { MainActor.assumeIsolated { old.deliver(["6901028075831"]) }; done.fulfill() }
        s.stop()
        s.start()
        wait(for: [done], timeout: 2)
        flush(s)
        XCTAssertEqual(codes, [], "旧回调在新一轮识别里执行也不交码")
    }

    func testStoppedSessionDeliversNothingAndRemovesTheCallback() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let r = try! XCTUnwrap(out.relay)
        s.stop()
        r.deliver(["6921168509256"])
        flush(s)
        r.deliver(["6921168509256"])
        XCTAssertEqual(codes, [])
        XCTAssertNil(out.relay, "停了摘掉回调")
    }

    // MARK: 整帧交付后换代（PR #17 Codex 第三轮；PR #40 第三轮起一帧整帧交给扫码层判定）

    /// 一帧 3 个码整帧交出；交的时候 `onFrame` 同步触发 `trigger`（换代），同一个旧回调再交的帧必须丢掉
    private func assertLaterFramesDropped(_ name: String, trigger: @escaping (CameraSession) -> Void) {
        codes = []
        let out = FakeOutput()
        let s = CameraSession(testOutput: out)
        var frames = 0
        s.onFrame = { [unowned self, unowned s] frame in
            frames += 1
            codes += frame.map(\.value)
            if frames == 1 { trigger(s) }
        }
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let r = try! XCTUnwrap(out.relay)
        r.deliver(["6921168509256", "6901028075831", "6954767412345"])
        XCTAssertEqual(codes, ["6921168509256", "6901028075831", "6954767412345"], "一帧整帧交出（\(name)）")
        r.deliver(["6921168509256"])
        flush(s)
        r.deliver(["6921168509256"])
        XCTAssertEqual(frames, 1, "换代之后旧回调的帧丢掉（\(name)）")
    }

    func testFramesFromTheOldRelayAreDroppedAfterTheEpochChanges() {
        assertLaterFramesDropped("停用") { $0.stop() }
        assertLaterFramesDropped("停用再启用") { $0.stop(); $0.start() }
        assertLaterFramesDropped("范围无效") { $0.setRectOfInterest(nil) }
        assertLaterFramesDropped("换识别范围") { $0.setRectOfInterest(CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5)) }
    }

    func testControllerStoppedAfterAFrameDeliversNoMoreFrames() {
        let out = FakeOutput()
        let s = CameraSession(testOutput: out)
        let perm = CameraPermission(status: { .authorized }, requester: { true })
        let c = CameraController(runner: s, permission: perm)
        var frames = 0
        c.onFrame = { [unowned self] frame in
            frames += 1
            codes += frame.map(\.value)
            c.update(visible: false, sceneActive: true)   // 交这一帧时离开页面
        }
        s.setRectOfInterest(visible)
        c.update(visible: true, sceneActive: true)
        flush(s)
        let r = try! XCTUnwrap(out.relay)
        r.deliver(["6921168509256", "6901028075831"])
        r.deliver(["6954767412345"])
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(codes, ["6921168509256", "6901028075831"])
        XCTAssertFalse(c.running)
    }

    // MARK: 识别范围（§14 S14-2，PR #17 Codex 第二轮 2）

    func testNoCodesBeforeAVisibleRectIsSet() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.start()
        flush(s)
        XCTAssertNil(out.relay, "范围没就绪不装回调（不认全画面）")
        s.setRectOfInterest(nil)   // 会话没跑、换算不准时预览视图交 nil
        flush(s)
        XCTAssertNil(out.relay)
        s.setRectOfInterest(visible)
        flush(s)
        XCTAssertEqual(out.rectOfInterest, visible, "先设范围再装回调")
        try! XCTUnwrap(out.relay).deliver(["6921168509256"])
        XCTAssertEqual(codes, ["6921168509256"])
    }

    func testInvalidRectStopsDeliveringImmediatelyAndNeverWidensToFullFrame() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let r = try! XCTUnwrap(out.relay)
        for bad in [CGRect.null, .zero, CGRect(x: 3, y: 3, width: 1, height: 1),
                    CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), .infinite] {
            s.setRectOfInterest(bad)
            r.deliver(["6921168509256"])   // 换算失败那一刻已经排着的码
            flush(s)
            XCTAssertNil(out.relay, "换算失败摘掉回调：\(bad)")
            XCTAssertEqual(out.rectOfInterest, visible, "不退回整个画面：\(bad)")
        }
        XCTAssertEqual(codes, [])
    }

    func testChangingTheRectDropsCodesFromTheOldRange() {
        let out = FakeOutput()
        let s = makeSession(out)
        s.setRectOfInterest(visible)
        s.start()
        flush(s)
        let old = try! XCTUnwrap(out.relay)
        let narrower = CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5)
        s.setRectOfInterest(narrower)
        old.deliver(["6921168509256"])
        flush(s)
        old.deliver(["6921168509256"])
        XCTAssertEqual(codes, [], "旧范围下认出的码丢掉")
        XCTAssertEqual(out.rectOfInterest, narrower)
        try! XCTUnwrap(out.relay).deliver(["6901028075831"])
        XCTAssertEqual(codes, ["6901028075831"])
    }

    func testValidRectOfInterestClampsOrRejects() {
        XCTAssertEqual(CameraSession.validRectOfInterest(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)),
                       CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3))
        XCTAssertEqual(CameraSession.validRectOfInterest(CGRect(x: -0.25, y: 0.25, width: 1.5, height: 0.5)),
                       CGRect(x: 0, y: 0.25, width: 1, height: 0.5), "越界部分裁掉（只会收窄）")
        XCTAssertNil(CameraSession.validRectOfInterest(.zero), "算不出来时不交码，不认整个画面")
        XCTAssertNil(CameraSession.validRectOfInterest(.null))
        XCTAssertNil(CameraSession.validRectOfInterest(.infinite))
        XCTAssertNil(CameraSession.validRectOfInterest(CGRect(x: 3, y: 3, width: 1, height: 1)))
        XCTAssertNil(CameraSession.validRectOfInterest(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
        XCTAssertNil(CameraSession.validRectOfInterest(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)))
    }

    func testPreviewReportsNotReadyUntilTheSessionRuns() {
        let v = CameraPreviewView(frame: CGRect(x: 0, y: 0, width: 300, height: 112))
        v.previewLayer.session = AVCaptureSession()   // 没在跑
        var reported: [CGRect?] = []
        v.onVisibleRect = { reported.append($0) }
        v.setNeedsLayout()
        v.layoutIfNeeded()
        XCTAssertEqual(reported, [nil], "会话没跑时换算不准：交「未就绪」，不交一个范围")
        v.setNeedsLayout()
        v.layoutIfNeeded()
        XCTAssertEqual(reported, [nil], "没变不重复交")
    }

    // MARK: 出错后自动重启的上限（PR #17 Fable 第二轮：1 秒内最多一次）

    func testRestartLimiterAllowsAtMostOncePerSecond() {
        var l = RestartLimiter()
        XCTAssertTrue(l.allow(at: 100))
        XCTAssertFalse(l.allow(at: 100.2))
        XCTAssertFalse(l.allow(at: 100.99))
        XCTAssertTrue(l.allow(at: 101.0))
        XCTAssertFalse(l.allow(at: 101.5))
        XCTAssertTrue(l.allow(at: 90), "时钟倒退时放行，不会永远卡住")
    }
}
