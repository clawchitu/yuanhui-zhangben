@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// 相机识别条码：`AVCaptureMetadataOutput`（§1：EAN-13 / EAN-8 / UPC-E / ITF-14 / Code128；扫码登录另加 QR）。
/// 会话的配置、启动、停止都在自己的串行队列上做；认出的码在主线程交给 `onCode`（再由 `ScanHub` 去重）。
final class CameraSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    static let productTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .itf14, .code128]

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cn.yuanhuishop.zhangben.camera")
    private let types: [AVMetadataObject.ObjectType]
    private var configured = false
    /// 只在主线程读写
    @MainActor var onCode: ((String) -> Void)?

    /// 这台机器有没有后置相机（模拟器没有）
    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    init(includeQR: Bool = false) {
        types = Self.productTypes + (includeQR ? [.qr] : [])
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
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
            for code in codes { onCode?(code) }
        }
    }
}

/// 相机画面（预览层铺满）
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// SwiftUI 里的相机：出现时启动、消失时停止，认出的码交给 `hub`（相机去重在 hub 里做）。
struct CameraPreview: UIViewRepresentable {
    let hub: ScanHub
    var includeQR = false

    final class Coordinator {
        let camera: CameraSession
        init(includeQR: Bool) { camera = CameraSession(includeQR: includeQR) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(includeQR: includeQR) }

    func makeUIView(context: Context) -> CameraPreviewView {
        let v = CameraPreviewView()
        v.previewLayer.session = context.coordinator.camera.session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.accessibilityIdentifier = "scanner.preview"
        let hub = hub
        context.coordinator.camera.onCode = { hub.receive($0, from: .camera) }
        context.coordinator.camera.start()
        return v
    }

    func updateUIView(_ v: CameraPreviewView, context: Context) {}

    static func dismantleUIView(_ v: CameraPreviewView, coordinator: Coordinator) {
        coordinator.camera.stop()
    }
}
