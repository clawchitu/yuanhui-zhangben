@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// 相机会话的开关（正式实现是 `CameraSession`，测试换成记录器）
@MainActor
protocol CameraRunning: AnyObject {
    /// 开始识别（会话在自己的串行队列上启动）
    func start()
    /// 停止识别；调用之后已经排队的识别回调一律不再交出
    func stop()
    /// 认出的码（主线程）
    var onCode: ((String) -> Void)? { get set }
}

/// 相机识别条码：`AVCaptureMetadataOutput`（§1：EAN-13 / EAN-8 / UPC-E / ITF-14 / Code128；扫码登录另加 QR）。
/// 会话的配置、启动、停止、识别范围都在自己的串行队列上做，按调用顺序执行；认出的码在主线程交给 `onCode`。
/// 只认取景框里的码（§14 S14-2）：`rectOfInterest` 由预览视图布局后按可见范围设。
/// 会话出错（`runtimeErrorNotification`）或被打断后恢复时，只要还应该开着就重新启动。
final class CameraSession: NSObject, CameraRunning, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    static let productTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .itf14, .code128]

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cn.yuanhuishop.zhangben.camera")
    private let types: [AVMetadataObject.ObjectType]
    // 以下三个只在 `queue` 上读写
    private var configured = false
    private var wantsRunning = false
    private var output: AVCaptureMetadataOutput?
    private var rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// 只在主线程读写：停了之后已经排在主线程上的识别回调直接丢掉
    @MainActor private var delivering = false
    @MainActor var onCode: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// 这台机器有没有后置相机（模拟器没有）
    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    init(includeQR: Bool = false) {
        types = Self.productTypes + (includeQR ? [.qr] : [])
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.resumeIfWanted()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @MainActor func start() {
        delivering = true
        queue.async { [self] in
            wantsRunning = true
            if !configured { configure() }
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    @MainActor func stop() {
        delivering = false
        queue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    /// 出错或打断结束后：还该开着就重新启动（媒体服务重置后会话会停下）
    private func resumeIfWanted() {
        queue.async { [self] in
            if wantsRunning, configured, !session.isRunning { session.startRunning() }
        }
    }

    /// 识别范围（`metadataOutputRectConverted` 换算后的 0…1 坐标）
    func setRectOfInterest(_ rect: CGRect) {
        let rect = Self.clampedRectOfInterest(rect)
        queue.async { [self] in
            rectOfInterest = rect
            output?.rectOfInterest = rect
        }
    }

    /// 收进 0…1 的单位方块；算不出来（空、NaN、完全在外面）时认整个画面，不至于一个码都认不出
    static func clampedRectOfInterest(_ rect: CGRect) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !rect.isNull, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return full }
        let r = rect.standardized.intersection(full)
        return r.isNull || r.width <= 0 || r.height <= 0 ? full : r
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = types.filter(output.availableMetadataObjectTypes.contains)
        output.rectOfInterest = rectOfInterest
        self.output = output
        // 近距离扫小条码：能自动对焦近处就打开
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        configured = true
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            guard delivering else { return }
            for code in codes { onCode?(code) }
        }
    }
}

/// 相机什么时候开：页面看得见、App 在前台（scene `.active`）、相机允许、页面没让它暂停（被面板盖住等），
/// 四样都满足才开，任何一样不满足就停（§14 S14-3 ⑨）。停着时交来的码一律丢掉。
/// 每次从后台回到前台先重新读一次权限（用户可能刚在系统设置里改了，S14-3 ⑩）。
@MainActor
final class CameraController {
    let permission: CameraPermission
    private let runner: CameraRunning?
    /// 认出的码（通常接 `ScanHub.receive(_:from: .camera)`）
    var onCode: ((String) -> Void)?
    private(set) var running = false
    private var visible = false
    private var sceneActive = false
    private var paused = false

    /// `runner` 为 nil：这台机器没有相机，永远不开
    init(runner: CameraRunning?, permission: CameraPermission) {
        self.runner = runner
        self.permission = permission
        runner?.onCode = { [weak self] code in self?.receive(code) }
    }

    func update(visible: Bool, sceneActive: Bool, paused: Bool = false) {
        let cameBack = sceneActive && !self.sceneActive
        self.visible = visible
        self.sceneActive = sceneActive
        self.paused = paused
        if cameBack { permission.refresh() }
        sync()
    }

    /// 按当前状态开或停（权限在别处变了之后也调这个）
    func sync() {
        let want = visible && sceneActive && !paused && permission.access == .authorized && runner != nil
        guard want != running else { return }
        running = want
        if want { runner?.start() } else { runner?.stop() }
    }

    private func receive(_ code: String) {
        guard running else { return }
        onCode?(code)
    }
}

/// 相机画面（预览层铺满）。布局后把预览层的可见范围换算成识别坐标交给 `onVisibleRect`（设 `rectOfInterest`）。
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onVisibleRect: ((CGRect) -> Void)?
    private var lastRect: CGRect?
    private var startObserver: NSObjectProtocol?

    /// 会话开始跑之后预览层的换算才准：那时再算一次
    func watch(_ session: AVCaptureSession) {
        startObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastRect = nil
                self?.setNeedsLayout()
            }
        }
    }

    deinit {
        if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let rect = previewLayer.metadataOutputRectConverted(fromLayerRect: bounds)
        guard rect != lastRect else { return }
        lastRect = rect
        onVisibleRect?(rect)
    }
}

/// SwiftUI 里的相机画面。启停不归它管（`CameraController` 管），它只显示画面、设识别范围。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let v = CameraPreviewView()
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.accessibilityIdentifier = "scanner.preview"
        let camera = camera
        v.onVisibleRect = { camera.setRectOfInterest($0) }
        v.watch(camera.session)
        return v
    }

    func updateUIView(_ v: CameraPreviewView, context: Context) {}
}
