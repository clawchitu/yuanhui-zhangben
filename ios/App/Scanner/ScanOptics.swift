@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia

/// 扫码相机的光学参数（选哪颗镜头、放大多少、怎么对焦）。全是纯函数，模拟器上没有相机也能单测；
/// 真机上由 `CameraSession` 读设备参数后调这些函数、再把结果设到设备上。
///
/// 背景（TestFlight 真机反馈）：Pro 机型广角主摄最近对焦距离约 20 cm，凑近扫小条码会糊。按 Apple 示例 AVCamBarcode 的做法：
/// 1. 优先用虚拟多摄设备（三摄 → 双广角 → 双摄 → 广角），近距离时系统自动切到超广角（微距）；
/// 2. 按最近对焦距离和条码大小算出放大倍数，让用户离 15–30 cm 远就能把条码拍清楚，不用硬凑近；
/// 3. 连续自动对焦 + 限定近处范围，对焦点、测光点放在取景框中心；点一下取景区按那里对焦一次。
enum ScanOptics {
    /// 选镜头的先后（后置）：虚拟设备在前，最后退到广角单摄
    static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
    ]

    /// 按优先顺序挑第一个这台机器有的类型
    static func pickDeviceType(available: Set<AVCaptureDevice.DeviceType>) -> AVCaptureDevice.DeviceType? {
        preferredDeviceTypes.first(where: available.contains)
    }

    /// 估算用的条码宽度：EAN-13 标准尺寸约 37 mm（EAN-8 / UPC-E 更小，按最常见的 EAN-13 算）
    static let codeWidthMM: Float = 37
    /// 放大倍数上限（相对广角主摄 1 倍）：再大手一抖条码就出框
    static let maxRelativeZoom: CGFloat = 3
    /// 识别范围比可见取景框四周各大出的比例（相对框的宽高）：条码压在框边上也认
    static let roiPadding: CGFloat = 0.12

    /// Apple AVCamBarcode 的 `minimumSubjectDistanceForCode`：条码占满取景框 `fill` 比例时、
    /// 视角为 `fovDegrees` 的相机至少要离多远（mm）。
    static func minimumSubjectDistance(fovDegrees: Float, codeWidthMM: Float = codeWidthMM, fill: Float) -> Float {
        let radians = fovDegrees / 2 * .pi / 180
        let filledCodeSize = codeWidthMM / fill
        return filledCodeSize / tan(radians)
    }

    /// 画面短边方向的视角：`videoFieldOfView` 是长边（横拿）方向的；竖屏时取景框的横向对着画面短边
    static func shortAxisFOV(longAxisFOVDegrees fov: Float, width: Int32, height: Int32) -> Float {
        let long = Float(max(width, height)), short = Float(min(width, height))
        guard fov > 0, fov < 180, long > 0, short > 0 else { return fov }
        let half = fov / 2 * .pi / 180
        return 2 * atan(tan(half) * short / long) * 180 / .pi
    }

    /// 虚拟多摄设备上广角主摄接手时的放大倍数和下一颗（长焦）接手的倍数。
    /// `constituents` 按视角从宽到窄排（系统给的顺序），`switchOvers` 比它少一个。
    /// 没有广角（不该发生）或不是虚拟设备：从 1 倍起，没有上限
    static func wideBaseZoom(constituents: [AVCaptureDevice.DeviceType],
                             switchOvers: [CGFloat]) -> (base: CGFloat, next: CGFloat?) {
        guard let i = constituents.firstIndex(of: .builtInWideAngleCamera), switchOvers.count == constituents.count - 1
        else { return (1, nil) }
        let base = i == 0 ? 1 : switchOvers[i - 1]
        let next = i < switchOvers.count ? switchOvers[i] : nil
        return (base, next)
    }

    /// 要设的 `videoZoomFactor`（AVCamBarcode 的算法）：
    /// 条码占满取景框时该离的距离若比最近对焦距离还近，就放大「最近对焦距离 ÷ 该离的距离」倍——用户在能对上焦的距离就能把条码拍大。
    /// - `fovDegrees`：取景框横向对着的那条边、在 1 倍时的视角
    /// - `minimumFocusDistanceMM`：主摄（虚拟设备取广角那颗）的最近对焦距离，-1 = 不知道
    /// - `fill`：可见取景框横向占画面那条边的比例（0…1）
    /// - `base`：广角主摄接手的倍数（虚拟设备上超广角是 1 倍），结果不小于它
    /// - `next`：长焦接手的倍数，结果停在它下面（长焦近处对不上焦）
    static func zoomFactor(fovDegrees: Float, minimumFocusDistanceMM: Int, fill: CGFloat,
                           codeWidthMM: Float = codeWidthMM, base: CGFloat = 1, next: CGFloat? = nil,
                           maxZoom: CGFloat) -> CGFloat {
        let base = max(1, base)
        var upper = min(maxZoom, base * maxRelativeZoom)
        if let next, next > base { upper = min(upper, next * 0.95) }
        upper = max(upper, min(base, maxZoom))
        guard minimumFocusDistanceMM > 0, fovDegrees > 0, fovDegrees < 180, fill.isFinite, fill > 0
        else { return min(base, maxZoom) }
        let fill = Float(min(fill, 1))
        let subject = minimumSubjectDistance(fovDegrees: fovDegrees, codeWidthMM: codeWidthMM, fill: fill)
        guard subject.isFinite, subject > 0 else { return min(base, maxZoom) }
        let wanted = CGFloat(Float(minimumFocusDistanceMM) / subject)
        return min(max(wanted, base), upper, maxZoom)
    }

    /// 识别范围：可见取景框四周各放大一圈（`roiPadding`），收进 0…1；输入无效返回 nil
    static func paddedRectOfInterest(_ rect: CGRect?, padding: CGFloat = roiPadding) -> CGRect? {
        guard let rect, let valid = CameraSession.validRectOfInterest(rect) else { return nil }
        let padded = valid.insetBy(dx: -valid.width * padding, dy: -valid.height * padding)
        return CameraSession.validRectOfInterest(padded)
    }

    /// 取景框中心（识别坐标和对焦点坐标是同一套 0…1 坐标）
    static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 竖屏时取景框横向占画面的比例：识别坐标是横拿的（x 沿长边），竖屏的横向对着 y
    static func horizontalFill(ofVisibleRect rect: CGRect) -> CGFloat {
        rect.height
    }

    /// 设备支持哪些对焦 / 测光设置
    struct Capabilities: Equatable, Sendable {
        var continuousAutoFocus = true
        var autoFocus = true
        var focusPointOfInterest = true
        var autoFocusRangeRestriction = true
        var smoothAutoFocus = true
        var continuousAutoExposure = true
        var autoExpose = true
        var exposurePointOfInterest = true
    }

    /// 对一次焦要设的值（nil = 不支持，不动）
    struct FocusPlan: Equatable, Sendable {
        var focusMode: AVCaptureDevice.FocusMode?
        var focusPoint: CGPoint?
        var nearRange: Bool
        var smoothAutoFocusOff: Bool
        var exposureMode: AVCaptureDevice.ExposureMode?
        var exposurePoint: CGPoint?
        /// 点按对焦后打开：画面里东西一动就回到取景框中心连续对焦
        var monitorSubjectArea: Bool
    }

    /// 平时（`tapped == false`）：连续自动对焦 / 测光，点放在取景框中心；
    /// 点按（`tapped == true`）：按点的位置对一次焦、测一次光，画面一变再回到连续对焦（AVCam 的做法）。
    /// 一律限定近处、关掉平滑对焦（平滑对焦为拍视频设计，对得慢）。
    static func focusPlan(at point: CGPoint, tapped: Bool, caps: Capabilities) -> FocusPlan {
        let p = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        let focus: AVCaptureDevice.FocusMode? =
            tapped ? (caps.autoFocus ? .autoFocus : caps.continuousAutoFocus ? .continuousAutoFocus : nil)
                   : (caps.continuousAutoFocus ? .continuousAutoFocus : caps.autoFocus ? .autoFocus : nil)
        let exposure: AVCaptureDevice.ExposureMode? =
            tapped ? (caps.autoExpose ? .autoExpose : caps.continuousAutoExposure ? .continuousAutoExposure : nil)
                   : (caps.continuousAutoExposure ? .continuousAutoExposure : nil)
        return FocusPlan(focusMode: focus,
                         focusPoint: caps.focusPointOfInterest && focus != nil ? p : nil,
                         nearRange: caps.autoFocusRangeRestriction,
                         smoothAutoFocusOff: caps.smoothAutoFocus,
                         exposureMode: exposure,
                         exposurePoint: caps.exposurePointOfInterest && exposure != nil ? p : nil,
                         monitorSubjectArea: tapped)
    }
}

extension ScanOptics.Capabilities {
    init(_ d: AVCaptureDevice) {
        self.init(continuousAutoFocus: d.isFocusModeSupported(.continuousAutoFocus),
                  autoFocus: d.isFocusModeSupported(.autoFocus),
                  focusPointOfInterest: d.isFocusPointOfInterestSupported,
                  autoFocusRangeRestriction: d.isAutoFocusRangeRestrictionSupported,
                  smoothAutoFocus: d.isSmoothAutoFocusSupported,
                  continuousAutoExposure: d.isExposureModeSupported(.continuousAutoExposure),
                  autoExpose: d.isExposureModeSupported(.autoExpose),
                  exposurePointOfInterest: d.isExposurePointOfInterestSupported)
    }
}

extension AVCaptureDevice {
    /// 把对焦计划设到设备上（调用方已经 `lockForConfiguration`）。顺序按文档：先设点，再设模式，模式生效时才按新点对焦
    func apply(_ plan: ScanOptics.FocusPlan) {
        if plan.nearRange { autoFocusRangeRestriction = .near }
        if plan.smoothAutoFocusOff { isSmoothAutoFocusEnabled = false }
        if let p = plan.focusPoint { focusPointOfInterest = p }
        if let m = plan.focusMode { focusMode = m }
        if let p = plan.exposurePoint { exposurePointOfInterest = p }
        if let m = plan.exposureMode { exposureMode = m }
        isSubjectAreaChangeMonitoringEnabled = plan.monitorSubjectArea
    }

    /// 按扫码取景框横向占画面的比例 `fill` 算放大倍数（见 `ScanOptics.zoomFactor`）
    func scanZoomFactor(fill: CGFloat) -> CGFloat {
        let dims = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let fov = ScanOptics.shortAxisFOV(longAxisFOVDegrees: activeFormat.videoFieldOfView,
                                          width: dims.width, height: dims.height)
        var minFocus = minimumFocusDistance
        var base: CGFloat = 1, next: CGFloat?
        if isVirtualDevice {
            let parts = constituentDevices
            (base, next) = ScanOptics.wideBaseZoom(constituents: parts.map(\.deviceType),
                                                   switchOvers: virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) })
            // 近处要拍清楚的是广角主摄：按它的最近对焦距离算（超广角能更近，靠系统自动切微距）
            if let wide = parts.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
                minFocus = wide.minimumFocusDistance
            }
        }
        return ScanOptics.zoomFactor(fovDegrees: fov, minimumFocusDistanceMM: minFocus, fill: fill,
                                     base: base, next: next,
                                     maxZoom: activeFormat.videoMaxZoomFactor)
    }
}
