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

/// 识别结果输出端（正式是 `AVCaptureMetadataOutput`，测试换成记录器）。只在会话队列上用。
protocol MetadataOutputTarget: AnyObject {
    var rectOfInterest: CGRect { get set }
    func setMetadataObjectsDelegate(_ objectsDelegate: (any AVCaptureMetadataOutputObjectsDelegate)?,
                                    queue objectsCallbackQueue: DispatchQueue?)
}

extension AVCaptureMetadataOutput: MetadataOutputTarget {}

/// 相机识别条码：`AVCaptureMetadataOutput`（§1：EAN-13 / EAN-8 / UPC-E / ITF-14 / Code128；扫码登录另加 QR）。
/// 会话的配置、启动、停止、识别范围都在自己的串行队列上做，按调用顺序执行；认出的码在主线程交给 `onCode`。
///
/// 交码按「代」隔离（PR #17 Codex 第二轮 1、2）：主线程上每次 `start()` / `stop()` / `setRectOfInterest` 都换一代（`epoch`），
/// 并立刻关掉交码；会话队列按顺序做完这一代的设置后，才给输出端装上一个带这一代代号的新回调（`Relay`），
/// 再回主线程开交码（只开这一代）。旧代的回调哪怕已经排在主线程上，代号对不上一律丢掉——快速停用再启用也放不进旧码。
///
/// 只认取景框里的码（§14 S14-2）：`rectOfInterest` 由预览视图在会话跑起来、布局后按可见范围设。
/// 还没有有效范围、或者换算结果无效（空、NaN、完全在画面外）时不装回调、不交码，绝不退回整个画面。
/// 会话出错（`runtimeErrorNotification`）或被打断后恢复时，只要还应该开着就重新启动。
final class CameraSession: NSObject, CameraRunning, @unchecked Sendable {
    static let productTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .itf14, .code128]

    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated private let queue = DispatchQueue(label: "cn.yuanhuishop.zhangben.camera")
    nonisolated private let types: [AVMetadataObject.ObjectType]
    /// 真的去开停 `AVCaptureSession`（测试注入输出端时为假）
    nonisolated private let drivesSession: Bool
    // 以下只在 `queue` 上读写
    nonisolated(unsafe) private var configured = false
    nonisolated(unsafe) private var wantsRunning = false
    nonisolated(unsafe) private var output: MetadataOutputTarget?
    /// 有效的识别范围；nil = 还没有 / 换算失败，此时不交码
    nonisolated(unsafe) private var validRect: CGRect?
    nonisolated(unsafe) private var relay: Relay?
    nonisolated(unsafe) private var restartLimiter = RestartLimiter()
    /// 正在用的相机（真机）
    nonisolated(unsafe) private var device: AVCaptureDevice?
    /// 可见取景框（识别坐标，没放大一圈的）：放大倍数和默认对焦点按它算
    nonisolated(unsafe) private var visibleRect: CGRect?
    /// 只在主线程读写：当前这一代，和已经装好回调、允许交码的那一代
    @MainActor private(set) var epoch = 0
    @MainActor private var acceptedEpoch: Int?
    @MainActor var onCode: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// 这台机器有没有后置相机（模拟器没有）
    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    /// 扫码用的相机：后置虚拟多摄优先（三摄 → 双广角 → 双摄），近处系统自动切超广角微距；都没有退到广角单摄，
    /// 再没有就系统默认的（`ScanOptics.preferredDeviceTypes`）。手电筒（`Torch`）也用它，两处是同一个设备
    nonisolated static func preferredDevice() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: ScanOptics.preferredDeviceTypes,
                                                     mediaType: .video, position: .back).devices
        let type = ScanOptics.pickDeviceType(available: Set(found.map(\.deviceType)))
        return found.first { $0.deviceType == type } ?? AVCaptureDevice.default(for: .video)
    }

    init(includeQR: Bool = false) {
        types = Self.productTypes + (includeQR ? [.qr] : [])
        drivesSession = true
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.resumeIfWanted()
            })
        }
        // 点按对焦后画面一变（换了个商品）：回到取景框中心连续对焦
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil,
                                            queue: nil) { [weak self] note in
            self?.subjectAreaChanged(note.object as? AVCaptureDevice)
        })
    }

    /// 测试用：输出端换成记录器，不开真相机
    init(testOutput: MetadataOutputTarget) {
        types = Self.productTypes
        drivesSession = false
        super.init()
        output = testOutput
        configured = true
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 换一代并立刻关交码；返回新一代的代号
    @MainActor private func nextEpoch() -> Int {
        epoch += 1
        acceptedEpoch = nil
        return epoch
    }

    @MainActor func start() {
        let e = nextEpoch()
        queue.async { [self] in
            wantsRunning = true
            if !configured, drivesSession { configure() }
            if configured, drivesSession, !session.isRunning { session.startRunning() }
            install(epoch: e)
        }
    }

    @MainActor func stop() {
        let e = nextEpoch()
        queue.async { [self] in
            wantsRunning = false
            if drivesSession, session.isRunning { session.stopRunning() }
            install(epoch: e)
        }
    }

    /// 出错或打断结束后：还该开着就重新启动（媒体服务重置后会话会停下）。
    /// 重启有上限：1 秒内最多一次（相机坏了或一直被别的 App 占着时不连续重启转圈，PR #17 Fable 第二轮）
    nonisolated private func resumeIfWanted() {
        queue.async { [self] in
            guard wantsRunning, configured, drivesSession, !session.isRunning,
                  restartLimiter.allow(at: ProcessInfo.processInfo.systemUptime) else { return }
            session.startRunning()
        }
    }

    /// 识别范围（`metadataOutputRectConverted` 换算后的 0…1 坐标）；nil 或无效 = 范围未就绪，停止交码
    @MainActor func setRectOfInterest(_ rect: CGRect?) {
        let rect = rect.flatMap(Self.validRectOfInterest)
        let e = nextEpoch()
        queue.async { [self] in
            validRect = rect
            install(epoch: e)
        }
    }

    /// 可见取景框变了（识别坐标，没放大一圈的）：按它重算放大倍数，对焦 / 测光点放到它中心
    @MainActor func setVisibleRect(_ rect: CGRect?) {
        guard let rect = rect.flatMap(Self.validRectOfInterest) else { return }
        queue.async { [self] in
            visibleRect = rect
            tuneOptics()
        }
    }

    /// 点按取景区：按点的位置（设备坐标 0…1）对一次焦、测一次光
    @MainActor func focus(atDevicePoint point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        queue.async { [self] in
            configureDevice { d in d.apply(ScanOptics.focusPlan(at: point, tapped: true, caps: .init(d))) }
        }
    }

    nonisolated private func subjectAreaChanged(_ changed: AVCaptureDevice?) {
        queue.async { [self] in
            guard let device, changed == nil || changed === device else { return }
            configureDevice { d in
                d.apply(ScanOptics.focusPlan(at: centerPoint, tapped: false, caps: .init(d)))
            }
        }
    }

    /// 会话队列上：默认对焦点 = 取景框中心（还不知道框在哪时用画面中心）
    nonisolated private var centerPoint: CGPoint {
        visibleRect.map(ScanOptics.center(of:)) ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// 会话队列上：按取景框设放大倍数（AVCamBarcode 的算法）、连续自动对焦 / 测光到框中心
    nonisolated private func tuneOptics() {
        configureDevice { d in
            if let rect = visibleRect {
                let zoom = d.scanZoomFactor(fill: ScanOptics.horizontalFill(ofVisibleRect: rect))
                if zoom.isFinite, abs(d.videoZoomFactor - zoom) > 0.01 { d.videoZoomFactor = zoom }
            }
            d.apply(ScanOptics.focusPlan(at: centerPoint, tapped: false, caps: .init(d)))
        }
    }

    /// 会话队列上：锁住设备改设置（锁不上就算了，不影响识别）
    nonisolated private func configureDevice(_ body: (AVCaptureDevice) -> Void) {
        guard drivesSession, let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        body(device)
    }

    /// 收进 0…1 的单位方块；算不出来（空、NaN、完全在画面外）返回 nil——不交码，不退回整个画面
    nonisolated static func validRectOfInterest(_ rect: CGRect) -> CGRect? {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !rect.isNull, !rect.isInfinite,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        let r = rect.standardized.intersection(full)
        return r.isNull || r.width <= 0 || r.height <= 0 ? nil : r
    }

    /// 会话队列上：该开着且有有效范围，就先设范围、再装这一代的回调，最后回主线程开这一代的交码；否则摘掉回调
    nonisolated private func install(epoch e: Int) {
        guard let output else { return }
        guard wantsRunning, let rect = validRect else {
            relay = nil
            output.setMetadataObjectsDelegate(nil, queue: nil)
            return
        }
        output.rectOfInterest = rect
        let relay = Relay(owner: self, epoch: e)
        self.relay = relay
        // 先排「开交码」再装回调：这一代的回调到主线程时，交码一定已经开了（主队列先进先出）
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { if epoch == e { acceptedEpoch = e } }
        }
        output.setMetadataObjectsDelegate(relay, queue: .main)
    }

    /// 主线程：只交当前这一代、并且已经开了交码的码。
    /// 同一帧有多个码时每个码交出前都重新核对代号：交前一个码时 `onCode` 可能同步停用 / 重开 / 换范围（换代），
    /// 换代之后同批剩下的码全部丢掉（PR #17 Codex 第三轮）
    @MainActor fileprivate func deliver(_ codes: [String], epoch e: Int) {
        for code in codes {
            guard e == epoch, acceptedEpoch == e else { return }
            onCode?(code)
        }
    }

    nonisolated private func configure() {
        guard let device = Self.preferredDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.metadataObjectTypes = types.filter(output.availableMetadataObjectTypes.contains)
        self.output = output
        self.device = device
        configured = true
        // 虚拟多摄：让系统按距离自动切镜头（近处切超广角微距）
        if device.isVirtualDevice, (try? device.lockForConfiguration()) != nil {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            device.unlockForConfiguration()
        }
        // 取景框位置还不知道：先按画面中心连续对焦、限近处；框布局好后（`setVisibleRect`）再按框放大、移对焦点
        tuneOptics()
    }

    /// 某一代的识别回调：带着自己的代号，代号过期的码在 `deliver` 里丢掉
    final class Relay: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private weak var owner: CameraSession?
        let epoch: Int

        init(owner: CameraSession, epoch: Int) {
            self.owner = owner
            self.epoch = epoch
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated { deliver(codes) }
        }

        /// 主线程：把这一代认出的码交给会话（测试直接调它模拟排队的回调）
        @MainActor func deliver(_ codes: [String]) {
            owner?.deliver(codes, epoch: epoch)
        }
    }

    /// 测试用：等会话队列上已排的活做完
    nonisolated func waitForQueue() { queue.sync {} }
}

/// 出错后自动重启的限速：距上一次放行不到 `interval` 秒就不放行
struct RestartLimiter: Sendable {
    var interval: TimeInterval = 1
    private var last: TimeInterval?

    init(interval: TimeInterval = 1) { self.interval = interval }

    mutating func allow(at now: TimeInterval) -> Bool {
        if let last, now >= last, now - last < interval { return false }
        last = now
        return true
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
    /// 相机（重新）开起来时（暂停后恢复、回前台、页面重新出现）：接 `ScanHub.cameraResumed`，不重放上一次处理过的码
    var onResume: (() -> Void)?
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
        if want { onResume?(); runner?.start() } else { runner?.stop() }
    }

    private func receive(_ code: String) {
        guard running else { return }
        onCode?(code)
    }
}

/// 相机画面（预览层铺满）。布局后把预览层的可见范围换算成识别坐标交给 `onVisibleRect`（设 `rectOfInterest`）。
/// 会话没在跑时预览层的换算不准，交 nil（范围未就绪，不交码）；会话跑起来后再算一次。
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onVisibleRect: ((CGRect?) -> Void)?
    /// 点了取景区：点的位置换算成设备坐标（0…1）交出去，对一次焦
    var onTapFocus: ((CGPoint) -> Void)?
    private let focusMark = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        focusMark.fillColor = nil
        focusMark.strokeColor = UIColor(Tokens.Palette.tag).cgColor
        focusMark.lineWidth = 2
        focusMark.opacity = 0
        layer.addSublayer(focusMark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard previewLayer.session?.isRunning == true else { return }
        onTapFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: p))
        // 点的位置闪一个小方框
        let side = min(56, bounds.height - 8)
        focusMark.path = UIBezierPath(rect: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)).cgPath
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.7, 1]
        fade.duration = 0.9
        focusMark.add(fade, forKey: "fade")
    }
    /// 上次交出去的范围（外层 nil = 还没交过）
    private var lastRect: CGRect??
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
        let ready = bounds.width > 0 && bounds.height > 0 && previewLayer.session?.isRunning == true
        let rect: CGRect? = ready ? previewLayer.metadataOutputRectConverted(fromLayerRect: bounds) : nil
        if let lastRect, lastRect == rect { return }
        lastRect = .some(rect)
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
        // 识别范围 = 可见取景框四周各大一圈（条码压着框边也认）；放大倍数和对焦点按可见框算
        v.onVisibleRect = { rect in
            camera.setRectOfInterest(ScanOptics.paddedRectOfInterest(rect))
            camera.setVisibleRect(rect)
        }
        v.onTapFocus = { camera.focus(atDevicePoint: $0) }
        v.watch(camera.session)
        return v
    }

    func updateUIView(_ v: CameraPreviewView, context: Context) {}
}
