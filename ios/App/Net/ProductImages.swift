import Foundation
import Observation
import os
import ShopCore
import SwiftUI
import UIKit

/// 商品图（S22c）：界面这一侧。磁盘缓存和下载在 `ProductImageLoader`（actor，不在主线程）；这里管内存缓存、开关、
/// 会话代数，`Thumb` 从这里取图。
///
/// - `Thumb` 只同步读内存（`cached`）；没命中就 `load`：后台读盘 + 解码（`preparingForDisplay`），盘上也没有就让下载器插队。
///   主线程不做磁盘 IO，不解码。加载中显示首字，不转圈。
/// - 开关关（T11）：当场清内存、代数 +1（Thumb 立即回首字），下载器取消在飞请求、删整个 `product-images` 目录。
/// - 会话变化（退出、被踢、换身份、epoch 重建）：同样清掉；一个会话一个实例，会话结束 `shutdown`。
/// - 审核号（演示店）：`blocked`，直接不请求、不预取（服务器 403 是第二道）。收银员照常。
@MainActor @Observable
final class ProductImages {
    private(set) var enabled: Bool
    /// 清过几次（开关关、会话重置）。Thumb 手上的图代数不对就不显示
    private(set) var generation = 0
    /// 屏幕上等着的图到了：key → 次数（Thumb 据此重取）。只记被要过的，预取下来的不动界面
    private(set) var arrivals: [ImageKey: Int] = [:]
    /// 演示店：不请求、不显示
    let blocked: Bool

    @ObservationIgnored let loader: ProductImageLoader
    @ObservationIgnored private let db: LocalDB?
    @ObservationIgnored private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()
    @ObservationIgnored private var waiting: Set<ImageKey> = []
    @ObservationIgnored private var stopped = false
    #if DEBUG
    /// 调试探针：屏幕上正显示着真图的 Thumb 数、下载器发过的请求数（UI 测试读）
    var debugShown = 0
    #endif

    static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "images")

    /// 解码：后台线程上真解一遍 JPEG，解不出来不落盘（裁定 3）
    nonisolated static let decodes: @Sendable (Data) -> Bool = { ProductImageLoader.looksLikeJPEG($0) && UIImage(data: $0) != nil }

    init(db: LocalDB?, disk: ProductImageDisk, enabled: Bool, blocked: Bool,
         configuration: URLSessionConfiguration = .ephemeral,
         base: @escaping @Sendable () -> URL, token: @escaping @Sendable () -> String?,
         syncBusy: @escaping @Sendable () -> Bool) {
        self.db = db
        self.enabled = enabled && !blocked
        self.blocked = blocked
        let relay = Relay()
        loader = ProductImageLoader(disk: disk, enabled: enabled && !blocked, configuration: configuration, base: base, token: token,
                                    syncBusy: syncBusy, validate: Self.decodes, onEvent: { e in relay.forward(e) })
        relay.target = self
        let loader = loader
        Task { await loader.start() }   // 开关开着：删不是当前店的子目录；关着：整个缓存目录删掉
    }

    /// 下载器的事件转回主线程（下载器建好之前 self 还没有，先建个中转）
    final class Relay: @unchecked Sendable {
        weak var target: ProductImages?
        func forward(_ e: ProductImageLoader.Event) {
            Task { @MainActor [weak self] in self?.target?.handle(e) }
        }
    }

    private func handle(_ e: ProductImageLoader.Event) {
        guard !stopped else { return }
        switch e {
        case .stored(let k), .missing(let k):
            if waiting.remove(k) != nil { arrivals[k, default: 0] += 1 }
        }
    }

    // MARK: - Thumb 用

    /// 内存里有就给（主线程上只做这个）
    func cached(_ k: ImageKey) -> UIImage? {
        guard enabled, k.ver > 0 else { return nil }
        return memory.object(forKey: k.description as NSString)
    }

    /// 后台读盘解码；盘上没有正好这一版就让下载器插队，先给本机有的旧版（没有就 nil，显示首字）
    func load(_ k: ImageKey) async -> UIImage? {
        guard enabled, k.ver > 0 else { return nil }
        if let m = cached(k) { return m }
        let gen = generation, disk = loader.disk
        let found = await Task.detached(priority: .utility) { () -> (ImageKey, UIImage)? in
            guard let (key, data) = disk.best(k), let img = UIImage(data: data) else { return nil }
            return (key, img.preparingForDisplay() ?? img)
        }.value
        guard gen == generation, enabled else { return nil }
        if let (key, img) = found {
            memory.setObject(img, forKey: key.description as NSString)
            if key == k { return img }
        }
        waiting.insert(k)
        await loader.request(k)
        return found?.1
    }

    // MARK: - 时机

    /// 同步成功（商品流已拉完）、开关打开：查库（后台）→ 预取缺的
    func prefetch() {
        guard enabled, !stopped, let db else { return }
        let loader = loader
        Task.detached(priority: .utility) {
            guard let wants = try? db.imageWants() else { return }
            await loader.prefetch(wants)
        }
    }

    /// `/v1/config` 的 `product_images_enabled`（T11）
    func setEnabled(_ on: Bool) {
        let on = on && !blocked
        guard on != enabled, !stopped else { return }
        enabled = on
        let loader = loader
        if on {
            Task { await loader.setEnabled(true); self.prefetch() }
        } else {
            clearMemory()
            Task { await loader.setEnabled(false) }
        }
    }

    /// epoch 重建（同一个会话、投影重来）：取消、清内存、删整目录，删完接着预取一轮（两步串在一个任务里，不和新下载交错）
    func reset() {
        clearMemory()
        let loader = loader
        Task {
            await loader.reset()
            self.prefetch()
        }
    }

    /// 会话结束（退出、被踢、换身份、换店）：取消、清内存、删整目录，之后不再做任何事
    func shutdown() {
        guard !stopped else { return }
        clearMemory()
        stopped = true
        enabled = false
        let loader = loader
        Task { await loader.shutdown() }
    }

    func enterBackground() { let l = loader; Task { await l.suspend() } }
    func enterForeground() { let l = loader; Task { await l.resume() } }

    /// 留给 S22d-iOS：拍照上传成功后把这张图直接放进缓存
    func prime(_ data: Data, productId: UUID, ver: Int) {
        let l = loader
        let k = ImageKey(productId, ver)
        waiting.insert(k)
        Task { await l.prime(data, productId: productId, ver: ver) }
    }

    private func clearMemory() {
        memory.removeAllObjects()
        waiting.removeAll()
        arrivals.removeAll()
        generation += 1
    }
}

extension ProductImages {
    /// 正常启动：一个会话一个。地址只用 `bases.current`，令牌从钥匙串现读
    static func live(db: LocalDB, session: LocalSession, services: AppServices, syncBusy: @escaping @Sendable () -> Bool) -> ProductImages {
        let api = services.api, tokens = services.tokens, ref = session.tokenRef
        return ProductImages(db: db, disk: ProductImageDisk(storeId: session.storeId), enabled: services.imagesEnabled,
                             blocked: services.isDemoSession(session.deviceId),
                             base: { api.bases.current }, token: { (try? tokens.token(ref: ref)) ?? nil }, syncBusy: syncBusy)
    }
}

/// 同步在飞的标记（`SyncCoordinator` 设，下载器在后台线程读）
final class SyncBusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

extension EnvironmentValues {
    /// 当前会话的商品图；夹具、组件陈列页没有（Thumb 只显示首字）
    @Entry var productImages: ProductImages? = nil
}

#if DEBUG
/// 卡顿探针（`-uiFrameProbe`）：假扫码从开始喂到喂完这段时间里，主线程两帧之间最长隔了多久（CADisplayLink）
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var maxGapMs = 0
    private(set) var frames = 0
    private(set) var state = "idle"

    func begin() {
        guard ProcessInfo.processInfo.arguments.contains("-uiFrameProbe"), link == nil else { return }
        maxGapMs = 0; frames = 0; last = 0; state = "running"
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func end() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        state = "done"
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 { maxGapMs = max(maxGapMs, Int(((l.timestamp - last) * 1000).rounded())) }
        last = l.timestamp
        frames += 1
    }
}
#endif
