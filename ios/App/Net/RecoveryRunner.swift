import Foundation
import os
import ShopCore

/// 恢复队列的上传调度（S22b，§4.5）：每次打开 App、回到前台、每次同步之前（含兑码成功后第一次拉取之前）都试一遍，
/// 传不完不拦。同一时间只跑一趟（并发来的直接跳过，下一次触发再试）。上传本身在后台线程（会开写事务、压缩）。
final class RecoveryRunner: @unchecked Sendable {
    let uploader: RecoveryUploader
    /// 整个进程同一时间只跑一趟（登录页上的启动补传和登录后同步之前的补传可能撞上）：后来的等前一趟跑完再跑，
    /// 保证兑码后第一次拉取之前恢复队列确实传过一遍
    private static let lock = NSLock()
    /// 本进程探过旧会话的 epoch 了（只在持锁时读写）
    nonisolated(unsafe) private static var probed = false
    static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "recovery")

    init(uploader: RecoveryUploader) { self.uploader = uploader }

    /// 正常启动：旧令牌从钥匙串取，请求走 `APIClient`（同步 / 注销）。Debug 的 `-uiOffline` 当作没网
    @MainActor static func live(db: LocalDB, services: AppServices, args: [String] = ProcessInfo.processInfo.arguments) -> RecoveryRunner {
        let api = services.api
        #if DEBUG
        // -uiRecoveryOffline：只有恢复队列连不上（联调「被踢后还剩几笔没传」）
        let offline = args.contains("-uiOffline") || args.contains("-uiRecoveryOffline")
        #else
        let offline = false
        #endif
        let uploader = RecoveryUploader(db: db, tokens: services.tokens, appBuild: services.build) { call in
            if offline { throw APIError.transport("模拟没网") }
            switch call {
            case .sync(let token, let body):
                SyncStats.shared.sent()
                return try Blocking.wait { try await api.sync(body: body, token: token) }
            case .logout(let token):
                return (try Blocking.wait { try await api.logout(token: token) }, Data())
            }
        }
        return RecoveryRunner(uploader: uploader)
    }

    /// 同步地跑一趟（调用方已在后台线程，不许在主线程等锁）。没网等失败返回 nil（不拦）
    func runBlocking() -> RecoveryReport? {
        precondition(!Thread.isMainThread, "恢复队列不在主线程传")
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // 启动、回前台、当前会话刚握手换了 epoch 时探一下旧会话那家店换没换 epoch（§4.6）；没探成（5xx、没网）下趟再探
        let probe = !Self.probed
        do {
            let r = try uploader.run(probeEpochs: probe)
            if probe && !r.probeIncomplete { Self.probed = true }
            return r
        } catch {
            Self.logger.notice("恢复队列这趟没传完：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 下一趟恢复上传要探 epoch（回前台、当前会话握手之后）
    static func requestProbe() { lock.lock(); probed = false; lock.unlock() }

    /// 在后台跑一趟
    func run() async -> RecoveryReport? {
        await Task.detached(priority: .utility) { self.runBlocking() }.value
    }
}
