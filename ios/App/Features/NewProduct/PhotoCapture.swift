import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// 压好的照片（S22d）：上传件（长边 ≤ 1024px、JPEG、≤ 400 KB）和 200px 预览
struct CompressedPhoto: Equatable, Sendable {
    let upload: Data
    let preview: Data
}

/// 拍照 / 相册的图在手机上压（规格⑦：长边 ≤ 1024px、JPEG、≤ 400 KB；服务器硬上限 1 MB，存 200px）。
/// 按显示方向重绘（EXIF 方向烘进像素，输出不带 EXIF、GPS），不放大；质量从 0.8 往下降到 0.4，还超就缩到 768 再来一遍。
/// 不在主线程调。
enum PhotoCompressor {
    static let maxSide: CGFloat = 1024
    static let fallbackSide: CGFloat = 768
    static let maxBytes = 400 * 1024
    static let previewSide: CGFloat = 200

    /// 相册原图（可能是 48MP、全景）不整张解开：ImageIO 直接按方向转正、缩到长边 1024 再交给 `compress`
    static func downsample(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: Int(maxSide)]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func compress(_ image: UIImage) -> CompressedPhoto? {
        for side in [maxSide, fallbackSide] {
            let scaled = redraw(image, maxSide: side)
            for q in stride(from: 0.8, through: 0.4, by: -0.1) {
                if let d = scaled.jpegData(compressionQuality: q), d.count <= maxBytes {
                    guard let p = redraw(image, maxSide: previewSide).jpegData(compressionQuality: 0.8) else { return nil }
                    return CompressedPhoto(upload: d, preview: p)
                }
            }
        }
        return nil
    }

    /// 按显示方向重绘到长边不超过 `maxSide`（scale = 1，不放大）
    static func redraw(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size   // 已按方向（.right 时宽高对调）
        let k = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * k).rounded(.down)), height: max(1, (size.height * k).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// 系统相机（真机）。模拟器没有相机：Debug 的 `-uiFakeCamera` 换成 `FakeCameraView`，后面的压缩、暂存、上传是同一条路
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.cameraCaptureMode = .photo
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(_ f: @escaping (UIImage?) -> Void) { onImage = f }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
    }
}

#if DEBUG
/// UI 测试的假相机（`-uiFakeCamera`）：一个取景页，要真点「拍照」才出图。出的是 4032×3024、方向 `.right`（竖着拿手机拍的样子）、
/// 带噪点的大图，压缩要真的降质量、方向要真的烘进像素
struct FakeCameraView: View {
    let onImage: (UIImage?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("假相机（UI 测试）").font(.title2.bold()).foregroundStyle(.white)
            Spacer()
            HStack(spacing: 40) {
                Button("取消") { onImage(nil) }.font(.title3).foregroundStyle(.white).accessibilityIdentifier("fakeCamera.cancel")
                Button { onImage(Self.shot()) } label: {
                    Circle().fill(.white).frame(width: 76, height: 76)
                }
                .accessibilityLabel("拍照")
                .accessibilityIdentifier("fakeCamera.shutter")
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    static func shot() -> UIImage {
        let w = 4032, h = 3024
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { c in
            var rng = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: h, by: 24) {
                for x in stride(from: 0, to: w, by: 24) {
                    UIColor(hue: CGFloat.random(in: 0...1, using: &rng), saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                    c.fill(CGRect(x: x, y: y, width: 24, height: 24))
                }
            }
        }
        return UIImage(cgImage: img.cgImage!, scale: 1, orientation: .right)
    }
}
#endif

/// 「拍一张」「从相册选」两个按钮和它们弹出来的相机 / 相册（选图页、没图提示页、进货页商品卡共用）。
/// 拿到图在后台压缩，压好交给 `onPhoto`；压不出来（极少见）给一句话
struct PhotoButtons: View {
    let mode: ShopMode
    let onPhoto: (CompressedPhoto) -> Void
    @State private var camera = false
    @State private var album: PhotosPickerItem?
    @State private var working = false
    @State private var failed = false
    /// 相机权限被拒：不弹系统相机（会黑屏），提示去设置里打开；相册照常能用
    @State private var cameraDenied = false

    static var fakeCamera: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiFakeCamera")
        #else
        false
        #endif
    }

    var body: some View {
        HStack(spacing: 10) {
            if CameraPicker.available || Self.fakeCamera {
                PrimaryButton("拍一张", systemImage: "camera", mode: mode, style: .dark, size: .small) {
                    if Self.cameraBlocked { cameraDenied = true } else { camera = true }
                }
                    .disabled(working)
                    .accessibilityIdentifier("photo.camera")
            }
            PhotosPicker(selection: $album, matching: .images, photoLibrary: .shared()) {
                Label("从相册选", systemImage: "photo.on.rectangle")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(Tokens.Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: PrimaryButton.Size.small.height)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .disabled(working)
            .accessibilityIdentifier("photo.album")
        }
        .overlay { if working { ProgressView().accessibilityIdentifier("photo.working") } }
        .alert("这张图用不了，换一张试试", isPresented: $failed) { Button("好") {} }
        .alert("相机没打开", isPresented: $cameraDenied) {
            Button("去设置打开") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("先从相册选", role: .cancel) {}
        } message: {
            Text("在「设置」里找到「元辉账本」，把「相机」打开就能拍照")
        }
        .fullScreenCover(isPresented: $camera) {
            cameraView { img in
                camera = false
                if let img { process(img) }
            }
        }
        .onChange(of: album) { _, item in
            guard let item else { return }
            album = nil
            working = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let photo = await Task.detached(priority: .userInitiated) { data.flatMap(PhotoCompressor.downsample).flatMap(PhotoCompressor.compress) }.value
                finish(photo)
            }
        }
    }

    /// 相机权限被拒或受限（Debug 的 `-uiCamera denied` 当作被拒，和扫码页同一个参数）
    static var cameraBlocked: Bool {
        #if DEBUG
        if let v = UIFixture.value(for: "-uiCamera", in: ProcessInfo.processInfo.arguments) { return v == "denied" }
        if fakeCamera { return false }
        #endif
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        return st == .denied || st == .restricted
    }

    @ViewBuilder private func cameraView(_ done: @escaping (UIImage?) -> Void) -> some View {
        #if DEBUG
        if Self.fakeCamera { FakeCameraView(onImage: done) } else { CameraPicker(onImage: done).ignoresSafeArea() }
        #else
        CameraPicker(onImage: done).ignoresSafeArea()
        #endif
    }

    private func process(_ img: UIImage) {
        working = true
        Task {
            let photo = await Task.detached(priority: .userInitiated) { PhotoCompressor.compress(img) }.value
            finish(photo)
        }
    }

    private func finish(_ photo: CompressedPhoto?) {
        working = false
        if let photo { onPhoto(photo) } else { failed = true }
    }
}
