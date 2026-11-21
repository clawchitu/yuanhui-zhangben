import SwiftUI

/// 设置 →「扫码枪」：现在连没连（`ScannerGunMonitor`，接了别的蓝牙键盘也会显示「已连上」，§14 S14-4 接受），
/// 和扫码枪要怎么设。没有单独的设计稿，照 21b 的白卡样式；更细的设置说明随 S29 的店里设置说明一起写。
struct ScannerStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.scanner.title(model.layout), onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsCard {
                        HStack {
                            Text("扫码枪").font(TypeScale.body.weight(.bold))
                            Spacer(minLength: 8)
                            Text(model.scannerConnected ? "已连上" : "没连")
                                .font(TypeScale.body)
                                .foregroundStyle(model.scannerConnected ? Tokens.Palette.ink : Tokens.Palette.ink2)
                                .accessibilityIdentifier("scanner.connected")
                        }
                        .foregroundStyle(Tokens.Palette.ink)
                        .padding(16)
                        .frame(minHeight: Tokens.Size.minHitTarget)
                    }
                    Text("扫码枪用蓝牙连上这台手机，设成「键盘模式（HID）」，扫完一个码后面跟「回车」。连上以后在卖出页直接扫，不用点屏幕。")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.scanner.pageId)
    }
}
