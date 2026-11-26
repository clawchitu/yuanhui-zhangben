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

/// 扫码页（卖出 / 进货）的取景框尺寸和相机区高度（扫码页布局方案，负责人 + Fable 定）：
///
/// - 取景框宽 = 屏宽 86%（左右各 7%），高 = 屏高 23%（约 2:1）；垂直中心在屏高 64%
/// - 手电筒、手输条码紧贴取景框下方（间距 16pt）横排两个等宽大按钮（左右边和取景框齐，高 64pt）；
///   按钮下面剩的地方留在底部安全区上方（不再让按钮贴底，免得框和按钮之间空出一大块）
/// - 卖出页购物篮到第 3 行、进货页商品卡在、或系统辅助字号下，取景框收到屏高 16%，并连同按钮沉到按钮离底部安全区 16pt，
///   让出地方给上面的清单 / 商品卡
///
/// 比例按整个屏幕算（含状态栏和底部安全区），换算到页面安全区内的坐标。屏幕矮时相机区不小于放下取景框和按钮的高度。
struct ScanLayout: Equatable {
    static let finderWidthRatio: CGFloat = 0.86
    static let finderHeightRatio: CGFloat = 0.23
    static let compactFinderHeightRatio: CGFloat = 0.16
    static let finderCenterRatio: CGFloat = 0.64
    /// 相机区顶到取景框上沿
    static let topPadding: CGFloat = 12
    /// 取景框下沿到按钮（固定，按钮紧贴框下）
    static let buttonGap: CGFloat = 16
    static let buttonHeight: CGFloat = 64
    /// 两个按钮之间
    static let buttonSpacing: CGFloat = 12
    /// 按钮底到底部安全区的最小留白（屏幕矮时相机区至少留这么多）
    static let bottomPadding: CGFloat = 16
    /// 给上面让高度时取景框最矮收到多少（一维条码横着扫，框矮一点不影响识别）
    static let minFinderHeight: CGFloat = 72

    let finder: CGSize
    /// 底部安全区高度：相机区的深色背景要铺到屏幕底
    let bottomInset: CGFloat
    /// 相机区高度（取景框上沿往上 12pt 起，到底部安全区为止；安全区那一截由背景色铺满）
    let bandHeight: CGFloat
    var buttonWidth: CGFloat { (finder.width - Self.buttonSpacing) / 2 }

    /// - size: 页面安全区内的大小；insets: 安全区（GeometryReader 读到的）
    /// - minTop: 相机区上沿至少在安全区顶往下多少（上面的顶栏 + 购物篮要的高度 + 结算条）；不够时取景框连按钮先往下沉，
    ///   再把框收矮，最矮 `minFinderHeight`（卖出页：价签「买几个」那一栏不能被结算条盖住，真机 11/26）。0 = 不要求
    init(size: CGSize, insets: EdgeInsets, compact: Bool, minTop: CGFloat = 0) {
        let fullH = size.height + insets.top + insets.bottom
        let fullW = size.width + insets.leading + insets.trailing
        let normalH = (fullH * Self.finderHeightRatio).rounded()
        var h = compact ? (fullH * Self.compactFinderHeightRatio).rounded() : normalH
        bottomInset = insets.bottom
        // 取景框下沿换到安全区坐标。收小时取景框连同按钮往下沉，用掉按钮下面的空地（按钮底离安全区 16pt），
        // 上沿下移得更多，让上面的清单多露一行；只沉不升（屏幕矮、本来就没空地时下沿不动）
        let normalBottom = fullH * Self.finderCenterRatio + normalH / 2 - insets.top
        let lowest = size.height - Self.bottomPadding - Self.buttonHeight - Self.buttonGap
        var bottom = compact ? max(normalBottom, lowest) : normalBottom
        var top = bottom - h - Self.topPadding
        if minTop > top {
            bottom = max(bottom, lowest)
            h = min(h, max(Self.minFinderHeight, (bottom - Self.topPadding - minTop).rounded(.down)))
            top = bottom - h - Self.topPadding
        }
        finder = CGSize(width: (fullW * Self.finderWidthRatio).rounded(), height: h)
        let minBand = Self.topPadding + h + Self.buttonGap + Self.buttonHeight + Self.bottomPadding
        bandHeight = max(minBand, size.height - top).rounded()
    }

    /// 测试 / 预览用：没有 GeometryReader 时按 iPhone 17 的尺寸
    static let preview = ScanLayout(size: CGSize(width: 402, height: 778),
                                    insets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), compact: false)
}

/// 卖出页、进货页底部的相机区（扫码页布局方案；27a 被拒时换成 `NoCameraBand`）。
/// 取景框和按钮的尺寸固定（像键盘一样不随动态字号变）。
///
/// - 相机允许 / 还没问过：S14 的 `CameraViewfinder`（真相机预览 + 识别，启停由 `CameraController` 管），
///   框内下沿一句「条形码对准框里」；下面横排「手电筒」「手输条码」两个大按钮
/// - `holding`（进货页扫到了、上面的商品卡还没确认）：取景框压暗，写「已扫到，先确认上面这件」，按钮照常能点
/// - 被拒：S14 的 `NoCameraBand`（27a）：「去打开」跳系统设置，手输条码和扫码枪照常能用
struct CameraStrip: View {
    let hub: ScanHub
    let permission: CameraPermission
    /// 页面被面板盖住 / 弹窗时让相机停（§14 S14-3 ⑨）
    var paused: Bool
    let torchOn: Bool
    var layout: ScanLayout = .preview
    /// 压暗取景框（识别由页面暂停，相机不停：同一个码一直在画面里，恢复后也不会马上再算一次）
    var holding = false
    var onTorch: @MainActor () -> Void
    var onManual: @MainActor () -> Void

    static let buttonFill = Color(hex: 0x4C4744)
    static let labelSize: CGFloat = 20
    static let holdingText = "已扫到，先确认上面这件"

    var body: some View {
        // 被拒时直接用 NoCameraBand（自带 scanner.noCamera 标识）；外面再套一层带标识的容器会把它盖掉
        if permission.access == .denied {
            NoCameraBand(onManual: onManual)
                .background(alignment: .bottom) { bottomFill }
        } else {
            scanning
                .frame(maxWidth: .infinity)
                .background(NoCameraBand.background)
                .background(alignment: .bottom) { bottomFill }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sell.camera")
        }
    }

    /// 深色背景往下铺满底部安全区（页面在 GeometryReader 里，`ignoresSafeArea` 铺不过去）
    private var bottomFill: some View {
        NoCameraBand.background.frame(height: layout.bottomInset).offset(y: layout.bottomInset)
            .accessibilityHidden(true)
    }

    // MARK: 取景框 + 下面两个按钮

    private var scanning: some View {
        VStack(spacing: 0) {
            viewfinder
            Spacer().frame(height: ScanLayout.buttonGap)
            HStack(spacing: ScanLayout.buttonSpacing) {
                stripButton(torchOn ? "关手电筒" : "手电筒", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                            id: "sell.torch", highlighted: torchOn, action: onTorch)
                stripButton("手输条码", systemImage: "keyboard", id: "scanner.manual", highlighted: false, action: onManual)
            }
            Spacer(minLength: ScanLayout.bottomPadding)
        }
        .padding(.top, ScanLayout.topPadding)
        .frame(height: layout.bandHeight)
    }

    private func stripButton(_ title: String, systemImage: String, id: String, highlighted: Bool,
                             action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 24, weight: .semibold))
                Text(title).font(.system(size: Self.labelSize, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(highlighted ? Tokens.Palette.ink : Tokens.Palette.card)
            .frame(width: layout.buttonWidth, height: ScanLayout.buttonHeight)
            .background(highlighted ? Tokens.Palette.tag : Self.buttonFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier(id)
    }

    /// 取景框（S14 的 `CameraViewfinder`，四个黄角加粗），框内下沿一句「条形码对准框里」；暂停时压暗
    private var viewfinder: some View {
        CameraViewfinder(hub: hub, permission: permission,
                         hasCamera: permission.forced == nil && CameraSession.hasCamera, paused: paused,
                         corners: .bold)
            .overlay(alignment: .bottom) {
                if !holding {
                    Text("条形码对准框里")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(NoCameraBand.captionColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if holding {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78))
                        Text(Self.holdingText)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Tokens.Palette.card)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 16)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("scanner.holding")
                }
            }
            .frame(width: layout.finder.width, height: layout.finder.height)
            .animation(.easeOut(duration: 0.2), value: layout.finder.height)
    }
}
