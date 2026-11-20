import AVFoundation
import Observation
import UIKit

/// 相机权限三态。`restricted`（家长控制等）和 `denied` 一样扫不了，归为 `denied`。
enum CameraAccess: String, Equatable, Sendable, CaseIterable {
    /// 允许了：出取景框（真机上是相机画面）
    case authorized
    /// 还没问过：页面出现时弹系统询问，等待时出「正在打开相机…」
    case notDetermined
    /// 被拒或受限：27a / 27b「没打开相机，扫不了码」+「去打开」；扫码枪和手输条码照常能用
    case denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }
}

/// 相机权限的当前状态。回到前台时重新读一次（用户可能刚在系统设置里打开了相机）。
@MainActor @Observable
final class CameraPermission {
    private(set) var access: CameraAccess
    /// Debug 夹具强制的状态（`-uiCamera`）：固定不变、也不弹系统询问
    @ObservationIgnored let forced: CameraAccess?
    @ObservationIgnored private let status: () -> AVAuthorizationStatus
    @ObservationIgnored private let requester: () async -> Bool

    init(forced: CameraAccess? = nil,
         status: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         requester: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }) {
        self.forced = forced
        self.status = status
        self.requester = requester
        self.access = forced ?? CameraAccess(status())
    }

    func refresh() {
        guard forced == nil else { return }
        access = CameraAccess(status())
    }

    /// 还没问过时弹系统询问；其他状态什么都不做
    func requestIfNeeded() async {
        guard forced == nil, access == .notDetermined else { return }
        _ = await requester()
        refresh()
    }

    /// 「去打开」：跳到系统设置里本 App 那一页
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#if DEBUG
extension CameraPermission {
    /// `-uiCamera denied|authorized|notDetermined`：把相机权限当成这个值（只在 Debug，§14 S15-7）
    static func forcedAccess(from args: [String]) -> CameraAccess? {
        UIFixture.value(for: "-uiCamera", in: args).flatMap(CameraAccess.init(rawValue:))
    }
}
#endif
