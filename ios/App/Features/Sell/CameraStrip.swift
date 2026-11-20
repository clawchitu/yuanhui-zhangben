import AVFoundation
import SwiftUI
import UIKit

/// 相机权限（S14 的三态；S16 只用来决定相机条出 03 的取景框还是 27a 的「没打开相机」）
enum CameraAccess: String, Equatable, Sendable {
    case authorized, notDetermined, denied

    static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied   // denied / restricted 都扫不了
        }
    }
}

/// 手电筒：开关相机的补光灯。模拟器和没有闪光灯的机器上 `isAvailable` 为假。
@MainActor
enum Torch {
    private static var device: AVCaptureDevice? {
        AVCaptureDevice.default(for: .video).flatMap { $0.hasTorch ? $0 : nil }
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
/// 取景框里现在画的是稿子上的条码示意；真正的相机预览和识别由 S14 的扫码层放进 `viewfinder` 这个位置，
/// 扫到的码交给 `SellModel.scan`。扫码枪（S14）和手输条码（S17）不依赖相机，相机没打开时照常能用。
struct CameraStrip: View {
    let access: CameraAccess
    let torchOn: Bool
    var onTorch: () -> Void
    var onManual: () -> Void
    var onOpenSettings: () -> Void

    static let height: CGFloat = 112
    static let background = Color(hex: 0x2B2622)
    static let buttonFill = Color(hex: 0x4C4744)
    static let captionColor = Color(hex: 0xD9D2C4)
    static let labelSize: CGFloat = 17

    var body: some View {
        Group {
            if access == .denied { noCamera } else { scanning }
        }
        .frame(maxWidth: .infinity)
        .background(Self.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sell.camera")
    }

    // MARK: 03：取景框 + 手电筒 + 手输条码

    private var scanning: some View {
        HStack(spacing: 12) {
            stripButton(torchOn ? "关手电筒" : "手电筒", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        id: "sell.torch", highlighted: torchOn, action: onTorch)
            viewfinder
            stripButton("手输条码", systemImage: "keyboard", id: "sell.manual", highlighted: false, action: onManual)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
    }

    private func stripButton(_ title: String, systemImage: String, id: String, highlighted: Bool,
                             action: @escaping () -> Void) -> some View {
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

    /// 取景框：黄色对角框 + 扫描线 + 「条形码对准框里」。S14 把相机预览放在这一块里
    private var viewfinder: some View {
        VStack(spacing: 6) {
            ZStack {
                BarcodeGlyph()
                    .fill(Color(hex: 0x979492))
                    .frame(width: 120, height: 46)
                Rectangle().fill(Tokens.Palette.tag).frame(height: 2)
                FinderCorners()
                    .stroke(Tokens.Palette.tag, style: StrokeStyle(lineWidth: 4, lineCap: .square))
            }
            .frame(width: 180, height: 66)
            Text("条形码对准框里")
                .font(.system(size: Self.labelSize))
                .foregroundStyle(Self.captionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("相机取景框，条形码对准框里")
    }

    // MARK: 27a：没打开相机

    private var noCamera: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("没打开相机，扫不了码")
                .font(TypeScale.title.weight(.bold))
                .foregroundStyle(Tokens.Palette.card)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text("去打开")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Tokens.Palette.tag, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("sell.openCamera")
                Button(action: onManual) {
                    Label("手输条码", systemImage: "keyboard")
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Tokens.Palette.card)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.Palette.card, lineWidth: 2.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .accessibilityIdentifier("sell.manual")
            }
            Text("扫码枪照常能用")
                .font(TypeScale.secondary)
                .foregroundStyle(Self.captionColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .accessibilityIdentifier("sell.noCamera")
    }
}

/// 取景框左上、右下两个黄色直角
private struct FinderCorners: Shape {
    func path(in r: CGRect) -> Path {
        let l: CGFloat = 26
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        }
    }
}

/// 条码示意（粗细不一的竖条）
struct BarcodeGlyph: Shape {
    static let pattern: [CGFloat] = [3, 1, 2, 1, 1, 3, 2, 1, 3, 1, 1, 2, 3, 1, 2, 2, 1, 3, 1, 2, 2, 1, 3, 1, 1, 2, 3, 1, 2, 3]

    func path(in r: CGRect) -> Path {
        let units = Self.pattern.reduce(0, +)
        let u = r.width / units
        var x = r.minX
        return Path { p in
            for (i, w) in Self.pattern.enumerated() {
                if i.isMultiple(of: 2) { p.addRect(CGRect(x: x, y: r.minY, width: w * u, height: r.height)) }
                x += w * u
            }
        }
    }
}
