import ShopCore
import SwiftUI

/// 17a 下半「已登录的手机」：每台一行，别的手机带「让它退出」（先弹 26 确认面板）。开通页和「已登录的手机」页共用
struct DeviceListSection: View {
    @Bindable var pairing: PairingModel
    var showsHeader = true
    /// 嵌在哪一页（开通页 / 已登录的手机）：「让它退出」的确认抽屉挂这一页的标识
    var page: Route = .devices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                Text("已登录的手机")
                    .font(TypeScale.title)
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            if let devices = pairing.devices {
                let live = devices.filter { !$0.revoked }
                ForEach(Array(live.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Rectangle().fill(Tokens.Palette.line).frame(height: 1.5) }
                    DeviceRow(device: d, now: pairing.serverNow()) { pairing.confirmRevoke = d }
                }
                // 退出了、但补传上来的账还等着确认的手机（§4.5「『某手机』被退出前还有 N 笔别的账」）
                ForEach(devices.filter { $0.revoked && $0.heldCount > 0 }) { d in
                    Rectangle().fill(Tokens.Palette.line).frame(height: 1.5)
                    HeldDeviceRow(device: d)
                }
            } else if let err = pairing.devicesError {
                Text(err).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .accessibilityIdentifier("devices.error")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .confirmSheet(item: $pairing.confirmRevoke, page: page) { d in
            ConfirmPanel(title: "让「\(d.label)」退出？",
                         message: "退出后它要重新扫码才能用。还没传上去的账会先传完。",
                         confirmTitle: "让它退出", cancelTitle: "不了", mode: .neutral,
                         confirmStyle: .dark, confirmImage: nil,
                         confirmId: "devices.revoke.confirm", cancelId: "devices.revoke.cancel",
                         busy: pairing.revoking,
                         onConfirm: { Task { await pairing.revokeConfirmed() } },
                         onCancel: { pairing.confirmRevoke = nil })
            if let err = pairing.revokeError {
                Text(err).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("devices.revoke.error")
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let now: Date
    let onRevoke: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { info; Spacer(minLength: 8); button }
            VStack(alignment: .leading, spacing: 10) { info; button }
        }
        .padding(.vertical, 14)
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone").font(.system(size: 30)).foregroundStyle(Tokens.Palette.ink)
                .frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.title).font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink)
                Text(device.subtitle(now: now)).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("devices.row.\(device.label)")
    }

    @ViewBuilder private var button: some View {
        if !device.isMe {
            Button(action: onRevoke) {
                Text("让它退出")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.button).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                    .contentShape(Rectangle())
                    .fixedSize()
            }
            .buttonStyle(PressDimStyle())
            .accessibilityIdentifier("devices.revoke.\(device.label)")
        }
    }
}

/// 已经退出、还有待确认的账的手机：点「去看看」进「待确认的账」
private struct HeldDeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { info; Spacer(minLength: 8); link }
            VStack(alignment: .leading, spacing: 10) { info; link }
        }
        .padding(.vertical, 14)
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone.slash").font(.system(size: 30)).foregroundStyle(Tokens.Palette.ink2)
                .frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(device.label)（已退出）").font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.Palette.ink2)
                Text("退出前还有 \(device.heldCount) 笔账等你确认").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("devices.heldRow.\(device.label)")
    }

    private var link: some View {
        NavigationLink(value: Route.held) {
            Text("去看看")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(minHeight: 60)
                .background(Tokens.Palette.ink, in: RoundedRectangle(cornerRadius: Tokens.Radius.button))
                .fixedSize()
        }
        .buttonStyle(PressDimStyle())
        .accessibilityIdentifier("devices.held.\(device.label)")
    }
}

/// 设置 →「已登录的手机」：只有列表（开通在「给家里人 / 收银员开通」）
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: PairingModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.devices.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let pairing {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DeviceListSection(pairing: pairing, showsHeader: false)
                        Text("让它退出以后，那台手机要重新扫码才能用。")
                            .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await pairing.refreshDevices() }
            } else {
                OfflineNote(text: "要联网才能看")
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if pairing == nil { pairing = model.makePairingModel() }
            Task { await pairing?.refreshDevices() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.devices.pageId)
    }
}
