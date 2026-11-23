@preconcurrency import AVFoundation
import XCTest
@testable import YuanhuiZhangben

/// 扫码相机的光学参数（TestFlight 真机反馈「对不了焦、扫不出来」）：选镜头、按最近对焦距离放大、对焦计划、识别范围。
/// 模拟器上没有相机，相机配置都抽成了 `ScanOptics` 里的纯函数，这里直接测。
final class ScanOpticsTests: XCTestCase {
    // MARK: 选镜头

    func testPrefersVirtualDevicesThenWide() {
        let all: Set<AVCaptureDevice.DeviceType> = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
                                                    .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera]
        XCTAssertEqual(ScanOptics.pickDeviceType(available: all), .builtInTripleCamera, "Pro 机型：三摄（近处自动切超广角微距）")
        XCTAssertEqual(ScanOptics.pickDeviceType(available: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInDualWideCamera]),
                       .builtInDualWideCamera, "普通双摄机型：双广角")
        XCTAssertEqual(ScanOptics.pickDeviceType(available: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInDualCamera]),
                       .builtInDualCamera)
        XCTAssertEqual(ScanOptics.pickDeviceType(available: [.builtInWideAngleCamera]), .builtInWideAngleCamera, "单摄机型")
        XCTAssertNil(ScanOptics.pickDeviceType(available: []), "模拟器：没有相机")
        XCTAssertEqual(ScanOptics.preferredDeviceTypes,
                       [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera])
    }

    // MARK: 放大倍数（AVCamBarcode 的 minimumSubjectDistanceForCode）

    func testMinimumSubjectDistanceMatchesAppleFormula() {
        // 90° 视角、37 mm 条码占满：37 / tan(45°) = 37 mm
        XCTAssertEqual(ScanOptics.minimumSubjectDistance(fovDegrees: 90, fill: 1), 37, accuracy: 0.001)
        // 只占一半取景框：距离加倍
        XCTAssertEqual(ScanOptics.minimumSubjectDistance(fovDegrees: 90, fill: 0.5), 74, accuracy: 0.001)
    }

    func testShortAxisFOV() {
        // 16:9 画面长边 90°：短边 2·atan(tan45°·9/16) ≈ 58.72°
        XCTAssertEqual(ScanOptics.shortAxisFOV(longAxisFOVDegrees: 90, width: 1920, height: 1080), 58.72, accuracy: 0.01)
        XCTAssertEqual(ScanOptics.shortAxisFOV(longAxisFOVDegrees: 90, width: 1080, height: 1920), 58.72, accuracy: 0.01,
                       "宽高谁在前都一样")
        XCTAssertEqual(ScanOptics.shortAxisFOV(longAxisFOVDegrees: 60, width: 0, height: 0), 60, "尺寸不知道：原样返回")
    }

    func testProWideCameraZoomsToMinimumFocusDistance() {
        // Pro 机型广角单摄：短边视角约 42.5°、最近对焦 200 mm。条码占满框时该离 37/tan(21.25°) ≈ 95 mm，比 200 mm 近，
        // 放大 200/95 ≈ 2.1 倍：离 20 cm 时条码在框里一样大，对得上焦
        let z = ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: 1, maxZoom: 100)
        XCTAssertEqual(Double(z), 2.102, accuracy: 0.01)
        // 取景框只占画面一半宽：条码占满框时离得更远（190 mm），只差一点，放大 200/190 ≈ 1.05 倍
        let half = ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: 0.5, maxZoom: 100)
        XCTAssertEqual(Double(half), 1.051, accuracy: 0.01)
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 100, fill: 0.5, maxZoom: 100), 1)
        // 算出来很大时：不超过主摄 3 倍
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 1000, fill: 1, maxZoom: 100), 3)
    }

    func testNoZoomWhenCameraFocusesCloseEnoughOrUnknown() {
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 80, fill: 1, maxZoom: 100), 1,
                       "最近对焦 8 cm 比 95 mm 还近：不用放大")
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: -1, fill: 1, maxZoom: 100), 1,
                       "最近对焦距离不知道（-1）：不放大")
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: 0, maxZoom: 100), 1)
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: .nan, maxZoom: 100), 1)
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 0, minimumFocusDistanceMM: 200, fill: 1, maxZoom: 100), 1)
    }

    func testZoomRespectsDeviceMaximum() {
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: 1, maxZoom: 1.5), 1.5)
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: 42.5, minimumFocusDistanceMM: 200, fill: 1, base: 2, maxZoom: 1.5), 1.5,
                       "设备上限比主摄起点还小：按设备上限")
    }

    func testVirtualDeviceZoomStartsAtWideAndStaysBelowTele() {
        // 三摄：超广角 1 倍、广角 2 倍接手、长焦 6 倍接手
        let (base, next) = ScanOptics.wideBaseZoom(constituents: [.builtInUltraWideCamera, .builtInWideAngleCamera,
                                                                  .builtInTelephotoCamera], switchOvers: [2, 6])
        XCTAssertEqual(base, 2)
        XCTAssertEqual(next, 6)
        // 1 倍（超广角）的短边视角：tan 是广角的 2 倍 → 2·atan(2·tan 21.25°) ≈ 75.75°
        let uwFOV: Float = 2 * atan(2 * tan(21.25 * .pi / 180)) * 180 / .pi
        let z = ScanOptics.zoomFactor(fovDegrees: uwFOV, minimumFocusDistanceMM: 200, fill: 1, base: base, next: next, maxZoom: 100)
        XCTAssertEqual(Double(z), 2 * 2.102, accuracy: 0.02, "等于广角上的 2.1 倍")
        // 算出来很大时：不超过主摄 3 倍，也不到长焦接手（长焦近处对不上焦）
        let big = ScanOptics.zoomFactor(fovDegrees: uwFOV, minimumFocusDistanceMM: 1000, fill: 1, base: base, next: next, maxZoom: 100)
        XCTAssertEqual(Double(big), 5.7, accuracy: 0.001)
        let tele3 = ScanOptics.zoomFactor(fovDegrees: uwFOV, minimumFocusDistanceMM: 1000, fill: 1, base: 2, next: 3, maxZoom: 100)
        XCTAssertEqual(Double(tele3), 2.85, accuracy: 0.001)
        // 对焦够近：停在广角 1 倍（不退回超广角画面）
        XCTAssertEqual(ScanOptics.zoomFactor(fovDegrees: uwFOV, minimumFocusDistanceMM: 30, fill: 1, base: base, next: next,
                                             maxZoom: 100), 2)
    }

    func testWideBaseZoom() {
        XCTAssertTrue(ScanOptics.wideBaseZoom(constituents: [.builtInWideAngleCamera, .builtInTelephotoCamera],
                                              switchOvers: [2]) == (1, 2), "双摄：广角就是 1 倍")
        XCTAssertTrue(ScanOptics.wideBaseZoom(constituents: [.builtInUltraWideCamera, .builtInWideAngleCamera],
                                              switchOvers: [2]) == (2, nil), "双广角：广角 2 倍接手，没有长焦")
        XCTAssertTrue(ScanOptics.wideBaseZoom(constituents: [.builtInWideAngleCamera], switchOvers: []) == (1, nil))
        XCTAssertTrue(ScanOptics.wideBaseZoom(constituents: [.builtInUltraWideCamera, .builtInWideAngleCamera],
                                              switchOvers: []) == (1, nil), "切换倍数对不上：不猜")
    }

    // MARK: 识别范围

    func testPaddedRectOfInterestIsSlightlyLargerAndClamped() throws {
        // 竖屏取景框：横向占满画面短边（y 0…1），纵向是长边上的一窄条
        let visible = CGRect(x: 0.4, y: 0, width: 0.2, height: 1)
        let r = try XCTUnwrap(ScanOptics.paddedRectOfInterest(visible))
        XCTAssertEqual(r.minX, 0.376, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.248, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 0)
        XCTAssertEqual(r.height, 1, "收进 0…1")
        XCTAssertTrue(r.contains(visible), "一定盖住可见框")
        let mid = try XCTUnwrap(ScanOptics.paddedRectOfInterest(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        XCTAssertEqual(mid.minX, 0.19, accuracy: 1e-9)
        XCTAssertEqual(mid.maxY, 0.81, accuracy: 1e-9)
        XCTAssertNil(ScanOptics.paddedRectOfInterest(nil), "范围未就绪：还是不交码")
        XCTAssertNil(ScanOptics.paddedRectOfInterest(.zero))
        XCTAssertNil(ScanOptics.paddedRectOfInterest(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
    }

    func testCenterAndHorizontalFill() {
        let r = CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.8)
        XCTAssertEqual(ScanOptics.center(of: r), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(ScanOptics.horizontalFill(ofVisibleRect: r), 0.8, "竖屏：屏幕横向对着识别坐标的 y")
    }

    // MARK: 对焦

    func testDefaultFocusPlanIsContinuousNearAtFinderCenter() {
        let p = CGPoint(x: 0.5, y: 0.45)
        let plan = ScanOptics.focusPlan(at: p, tapped: false, caps: .init())
        XCTAssertEqual(plan, ScanOptics.FocusPlan(focusMode: .continuousAutoFocus, focusPoint: p, nearRange: true,
                                                  smoothAutoFocusOff: true, exposureMode: .continuousAutoExposure,
                                                  exposurePoint: p, monitorSubjectArea: false))
    }

    func testTapFocusIsOneShotAndWatchesSubjectArea() {
        let plan = ScanOptics.focusPlan(at: CGPoint(x: 0.3, y: 1.4), tapped: true, caps: .init())
        XCTAssertEqual(plan.focusMode, .autoFocus)
        XCTAssertEqual(plan.exposureMode, .autoExpose)
        XCTAssertEqual(plan.focusPoint, CGPoint(x: 0.3, y: 1), "点收进 0…1")
        XCTAssertEqual(plan.exposurePoint, CGPoint(x: 0.3, y: 1))
        XCTAssertTrue(plan.monitorSubjectArea, "画面一变回到连续对焦")
        XCTAssertTrue(plan.nearRange)
        XCTAssertTrue(plan.smoothAutoFocusOff)
    }

    func testFocusPlanSkipsUnsupportedSettings() {
        var caps = ScanOptics.Capabilities()
        caps.autoFocusRangeRestriction = false
        caps.smoothAutoFocus = false
        caps.focusPointOfInterest = false
        caps.exposurePointOfInterest = false
        caps.autoFocus = false
        let tap = ScanOptics.focusPlan(at: CGPoint(x: 0.5, y: 0.5), tapped: true, caps: caps)
        XCTAssertEqual(tap.focusMode, .continuousAutoFocus, "不支持单次对焦：退到连续对焦")
        XCTAssertNil(tap.focusPoint)
        XCTAssertNil(tap.exposurePoint)
        XCTAssertFalse(tap.nearRange)
        XCTAssertFalse(tap.smoothAutoFocusOff)
        let fixed = ScanOptics.Capabilities(continuousAutoFocus: false, autoFocus: false, focusPointOfInterest: true,
                                            autoFocusRangeRestriction: false, smoothAutoFocus: false,
                                            continuousAutoExposure: false, autoExpose: false, exposurePointOfInterest: true)
        let none = ScanOptics.focusPlan(at: CGPoint(x: 0.5, y: 0.5), tapped: false, caps: fixed)
        XCTAssertNil(none.focusMode, "定焦镜头：不设对焦")
        XCTAssertNil(none.focusPoint, "没有对焦模式就不设对焦点")
        XCTAssertNil(none.exposureMode)
        XCTAssertNil(none.exposurePoint)
    }
}
