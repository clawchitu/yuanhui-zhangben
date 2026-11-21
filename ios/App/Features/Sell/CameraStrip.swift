import AVFoundation
import SwiftUI
import UIKit

/// 手电筒：开关相机的补光灯。和 `CameraSession` 用同一个设备（`CameraSession.preferredDevice()`，PR #17 第 8 项）。
/// 模拟器和没有闪光灯的机器上 `isAvailable` 为假。真机上会话运行中开灯的表现留 S29 验。
@MainActor
enum Torch {
    private static var device: AVCaptureDevice? {
        CameraSession.preferredDevice().flatMap { $0.hasTorch ? $0 : nil }
    }

    static var isAvailable: Bool { device?.isTorchAvailable ?? false }

    /// 切换后的状态；切不了返回 nil
    static func set(_ on: Bool) -> Bool? {
        guard let d = device, d.isTorchAvailable else { return nil }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            d.torchMode = on ? .on : .off
            return on
        } catch {
            return nil
        }
    }
}

/// 卖出页顶上的相机条（03 / 27a）。高度、字号固定（像键盘一样不随动态字号变），只有 27a 的那句话走动态字号。
///
/// - 相机允许 / 还没问过：手电筒 + S14 的 `CameraViewfinder`（真相机预览 + 识别，启停由 `CameraController` 管）+ 手输条码
/// - 被拒：S14 的 `NoCameraBand`（27a）：「去打开」跳系统设置，手输条码和扫码枪照常能用
struct CameraStrip: View {
    let hub: ScanHub
    let permission: CameraPermission
    /// 页面被面板盖住 / 弹窗时让相机停（§14 S14-3 ⑨）
    var paused: Bool
    let torchOn: Bool
    var onTorch: @MainActor () -> Void
    var onManual: @MainActor () -> Void

    static let height: CGFloat = 112
    static let buttonFill = Color(hex: 0x4C4744)
    static let labelSize: CGFloat = 17

    var body: some View {
        Group {
            if permission.access == .denied {
                NoCameraBand(onManual: onManual)
            } else {
                scanning
            }
        }
        .frame(maxWidth: .infinity)
        .background(NoCameraBand.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.camera")
    }

    // MARK: 03：取景框 + 手电筒 + 手输条码

    private var scanning: some View {
        HStack(spacing: 12) {
            stripButton(torchOn ? "关手电筒" : "手电筒", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        id: "sell.torch", highlighted: torchOn, action: onTorch)
            viewfinder
            stripButton("手输条码", systemImage: "keyboard", id: "scanner.manual", highlighted: false, action: onManual)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
    }

    private func stripButton(_ title: String, systemImage: String, id: String, highlighted: Bool,
                             action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 26, weight: .semibold))
                Text(title).font(.system(size: Self.labelSize, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(highlighted ? Tokens.Palette.ink : Tokens.Palette.card)
            .frame(width: 84, height: 76)
            .background(highlighted ? Tokens.Palette.tag : Self.buttonFill, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier(id)
    }

    /// 取景框（S14 的 `CameraViewfinder`）+ 下面一句「条形码对准框里」
    private var viewfinder: some View {
        VStack(spacing: 6) {
            CameraViewfinder(hub: hub, permission: permission,
                             hasCamera: permission.forced == nil && CameraSession.hasCamera, paused: paused)
                .frame(width: 180, height: 66)
            Text("条形码对准框里")
                .font(.system(size: Self.labelSize))
                .foregroundStyle(NoCameraBand.captionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}
