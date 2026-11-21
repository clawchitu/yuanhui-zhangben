import XCTest
@testable import YuanhuiZhangben

/// S14 验收：`FakeScanner` 能由启动参数喂码（只在 Debug 编译，§14 S15-7；Release 里不认见 ReleaseBuildUITests）。
@MainActor
final class FakeScannerTests: XCTestCase {
    func testParsesLaunchArguments() throws {
        XCTAssertNil(FakeScanner.from([]))
        XCTAssertNil(FakeScanner.from(["-uiScan", ""]))
        let f = try XCTUnwrap(FakeScanner.from(["-uiScan", "6921168509256,6921168509256,6900000000000",
                                                "-uiScanSource", "camera", "-uiScanGap", "0.2", "-uiScanDelay", "0"]))
        XCTAssertEqual(f.codes, ["6921168509256", "6921168509256", "6900000000000"])
        XCTAssertEqual(f.source, .camera)
        XCTAssertEqual(f.gap, 0.2)
        XCTAssertEqual(f.delay, 0)
        let d = try XCTUnwrap(FakeScanner.from(["-uiScan", "123456", "-uiScanSource", "bogus"]))
        XCTAssertEqual(d.source, .gun, "默认当扫码枪")
        XCTAssertEqual(d.gap, 0.3)
    }

    /// 扫码枪模式下按键序列和真扫码枪一样经过 HIDScanParser，恰好出一次码
    func testGunKeystrokesGoThroughTheRealParser() {
        var p = HIDScanParser()
        let scans = FakeScanner.keystrokes("6921168509256", start: 10).compactMap { p.feed($0.0, at: $0.1) }
        XCTAssertEqual(scans, ["6921168509256"])
        XCTAssertLessThan(FakeScanner.keyGap, HIDScanParser.Config().maxGap)
    }

    func testRunFeedsTheHub() async {
        var got: [Scan] = []
        let hub = ScanHub()
        hub.handler = { got.append($0); return .known }
        let gun = FakeScanner(codes: ["6921168509256", "6921168509256"], source: .gun, gap: 0, delay: 0)
        await gun.run(into: hub)
        XCTAssertEqual(got, Array(repeating: Scan(code: "6921168509256", source: .gun), count: 2), "扫码枪每次都算")
        got = []
        let cam = FakeScanner(codes: ["6921168509256", "6921168509256", "6901035600016"], source: .camera, gap: 0, delay: 0)
        await cam.run(into: hub)
        XCTAssertEqual(got.map(\.code), ["6921168509256", "6901035600016"], "相机同码 1.5 秒内只算一次")
    }

    func testCameraPermissionThreeStates() async {
        XCTAssertEqual(CameraAccess(.authorized), .authorized)
        XCTAssertEqual(CameraAccess(.notDetermined), .notDetermined)
        XCTAssertEqual(CameraAccess(.denied), .denied)
        XCTAssertEqual(CameraAccess(.restricted), .denied, "受限也扫不了")
        // 没问过 → 弹询问 → 按用户的选择变成允许
        let status = AVAuthorizationStatusBox(.notDetermined)
        var asked = 0
        let p = CameraPermission(status: { status.value }, requester: { asked += 1; status.value = .authorized; return true })
        XCTAssertEqual(p.access, .notDetermined)
        await p.requestIfNeeded()
        XCTAssertEqual(p.access, .authorized)
        await p.requestIfNeeded()
        XCTAssertEqual(asked, 1, "问过一次就不再问")
        // 回到前台时重新读（用户去系统设置里关了）
        status.value = .denied
        p.refresh()
        XCTAssertEqual(p.access, .denied)
        // 夹具强制的状态不变、不弹询问
        let forced = CameraPermission(forced: .denied, status: { .authorized }, requester: { asked += 1; return true })
        forced.refresh()
        await forced.requestIfNeeded()
        XCTAssertEqual(forced.access, .denied)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(CameraPermission.forcedAccess(from: ["-uiCamera", "denied"]), .denied)
        XCTAssertNil(CameraPermission.forcedAccess(from: ["-uiCamera", "nope"]))
    }
}

import AVFoundation
/// 测试里可变的权限状态
final class AVAuthorizationStatusBox: @unchecked Sendable {
    var value: AVAuthorizationStatus
    init(_ v: AVAuthorizationStatus) { value = v }
}
