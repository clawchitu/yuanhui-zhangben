import Foundation
import os
import ShopCore
import UIKit

/// 一次待发的换图（S22d）：选了一张候选图（`select`），或拍了 / 从相册选了一张照片（`photo`，PUT 上传）。
/// 同一个商品只留最后一次（文件名就是商品 id）：先选图后拍照，只发照片。
struct PendingImage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case select, photo }
    var kind: Kind
    var productId: UUID
    /// select：商品的单件码和候选 id（服务器按「条码挂在这个商品上、候选 ready」判）
    var barcode: String?
    var candidateId: String?
    var createdAt: Date
    /// 每一条自己的号：`createdAt` 存盘只到秒，同一秒里换了一次也要认得出「不是发出去的那一条」（① 存下的旧条目没有，读出来是 nil）
    var token: UUID? = UUID()
    /// 能发了（登记已确认）之后服务器回 404 的次数：满 3 次丢掉
    var notFound = 0
}

/// 待发换图的本机暂存（S22d，Fable 方案 5）：`Application Support/pending-images/<店>/<商品>.json`；
/// 要上传的照片（≤ 400 KB）存同名 `.jpg`，200px 预览（选图：候选缩图本身；照片：本机缩的一份；成功后 prime 用）存 `.thumb.jpg`。先写临时文件再改名；json 最后写，有 json 才算一条。
/// 不进账本库（不动迁移，出错碰不到账）；不放 Caches（系统会清）。按会话的店分目录，会话结束整个目录删掉。
/// 方法都是同步文件操作：只在后台线程调。
final class PendingImageStore: Sendable {
    let root: URL
    let storeId: UUID
    /// 每家店最多留几条，超了丢最旧的
    static let maxItems = 100
    /// 放多久还发不出去就丢掉（和 outbox 确认后保留天数一样）
    static let maxAge: TimeInterval = 14 * 86_400

    init(root: URL = PendingImageStore.defaultRoot(), storeId: UUID) {
        self.root = root
        self.storeId = storeId
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("pending-images", isDirectory: true)
    }

    var dir: URL { root.appendingPathComponent(storeId.uuidString.lowercased(), isDirectory: true) }
    private func json(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString.lowercased()).json") }
    private func jpg(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString.lowercased()).jpg") }
    private func thumb(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString.lowercased()).thumb.jpg") }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// 存一条（同一商品覆盖）。先写图片再写 json。`payload`：要上传的照片；`preview`：200px 预览
    func put(_ item: PendingImage, payload: Data? = nil, preview: Data? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let payload { try Self.atomicWrite(payload, to: jpg(item.productId)) } else { try? fm.removeItem(at: jpg(item.productId)) }
        if let preview { try Self.atomicWrite(preview, to: thumb(item.productId)) } else { try? fm.removeItem(at: thumb(item.productId)) }
        try Self.atomicWrite(try Self.encoder.encode(item), to: json(item.productId))
        try trim()
    }

    /// 只改记录（404 计数），不动图片
    func update(_ item: PendingImage) throws {
        guard FileManager.default.fileExists(atPath: json(item.productId).path) else { return }
        try Self.atomicWrite(try Self.encoder.encode(item), to: json(item.productId))
    }

    /// 全部待发的，按存入先后（读不出来的文件当作没有并删掉）
    func all() -> [PendingImage] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [PendingImage] = []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let item = try? Self.decoder.decode(PendingImage.self, from: d),
               f.deletingPathExtension().lastPathComponent == item.productId.uuidString.lowercased() {
                out.append(item)
            } else {
                try? fm.removeItem(at: f)
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    func payload(_ id: UUID) -> Data? { try? Data(contentsOf: jpg(id)) }
    /// 这个商品现在暂存的那一条（发的过程中可能被新选的图、新拍的照片换掉）
    func current(_ id: UUID) -> PendingImage? {
        (try? Data(contentsOf: json(id))).flatMap { try? Self.decoder.decode(PendingImage.self, from: $0) }
    }
    /// 200px 预览；① 存下的选图把候选缩图放在 `.jpg`，没有 `.thumb.jpg` 时退回去读它
    func preview(_ id: UUID) -> Data? { (try? Data(contentsOf: thumb(id))) ?? (current(id)?.kind == .select ? payload(id) : nil) }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: json(id))
        try? FileManager.default.removeItem(at: jpg(id))
        try? FileManager.default.removeItem(at: thumb(id))
    }

    /// 这家店的全部删掉（会话结束）
    func removeAll() { try? FileManager.default.removeItem(at: dir) }

    /// 不是这家店的目录删掉（上次的会话没走到正常结束，例如「重新登录」、强杀）
    func removeOtherStores() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for d in dirs where d.lastPathComponent != storeId.uuidString.lowercased() { try? fm.removeItem(at: d) }
    }

    private func trim() throws {
        let items = all()
        guard items.count > Self.maxItems else { return }
        for i in items.prefix(items.count - Self.maxItems) { remove(i.productId) }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

/// 把暂存的换图发给服务器（S22d，Fable 方案 5、6）。一次只跑一趟，跑的时候又来了触发就跑完再来一趟；一条一条串行发。
///
/// - 闸门：`LocalDB.imageGate`——这个商品的 `product_upsert` 还没确认就先不发（否则 404）。
/// - 什么时候跑：暂存当下、每次同步成功之后、会话建立时。只有暂存当下发现要等登记才踢一趟同步；
///   同步成功之后跑的那一趟不踢（不然登记一直传不上去时会一趟接一趟地同步）。
/// - 结果：成功 → 删掉、回调（prime + 预览记版本 + 踢一趟同步拉回新版本）；401、限速、5xx、连不上、开关关 → 留着等下一趟；
///   503（店忙）→ 等 `retry_after_s`（最多 5 秒）本趟再试一次；404 → 能发之后累计 3 次丢掉；400、403、413 → 丢掉；
///   登记被拒、本机没有这个商品 → 丢掉；放了 14 天 → 丢掉。
actor ImageUploader {
    struct Deps: Sendable {
        let store: PendingImageStore
        let gate: @Sendable (UUID) -> ImageGate
        let token: @Sendable () -> String?
        let select: @Sendable (_ productId: UUID, _ barcode: String, _ cid: String, _ token: String) async throws -> Int
        let upload: @Sendable (_ productId: UUID, _ jpeg: Data, _ token: String) async throws -> Int
        /// 开关开着、这个会话还能换图
        let enabled: @Sendable () async -> Bool
        /// 一条发成功了：商品、新版本、200px 预览（prime 用）
        let succeeded: @Sendable (UUID, Int, Data?) async -> Void
        /// 有要等登记确认的：踢一趟同步
        let needSync: @Sendable () async -> Void
        /// 一条丢掉了（发不出去）：本机预览也撤掉
        var dropped: @Sendable (UUID) async -> Void = { _ in }
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    enum Outcome: Equatable, Sendable { case sent(Int), keep, drop, stopRound, notFound }

    private let deps: Deps
    private var running = false
    private var again = false
    private var againKick = false
    private var stopped = false
    /// 发过几次请求（测试看）
    private(set) var attempts = 0

    static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "image-upload")

    init(_ deps: Deps) { self.deps = deps }

    func stop() { stopped = true }

    /// 存一条再发一趟。写盘和「停住、全删」都在这个 actor 里串行做：会话结束之后迟到的暂存不会再把目录写回来
    func enqueue(_ item: PendingImage, payload: Data?, preview: Data?) async {
        guard !stopped else { return }
        do { try deps.store.put(item, payload: payload, preview: preview) } catch {
            Self.logger.notice("换图暂存没写上：\(String(describing: error), privacy: .public)")
        }
        await flush(kickIfWaiting: true)
    }

    /// 会话结束：停住，这家店的暂存全删
    func stopAndClear() {
        stopped = true
        deps.store.removeAll()
    }

    /// 跑一趟。`kickIfWaiting`：有要等登记确认的就踢一趟同步（只在暂存当下传 true）
    func flush(kickIfWaiting: Bool) async {
        if running { again = true; againKick = againKick || kickIfWaiting; return }
        running = true
        var kick = kickIfWaiting
        repeat {
            again = false
            await once(kickIfWaiting: kick)
            kick = againKick
            againKick = false
        } while again && !stopped
        running = false
    }

    private func once(kickIfWaiting: Bool) async {
        guard !stopped, await deps.enabled() else { return }
        var waiting = false
        let now = deps.now()
        for item in deps.store.all() {
            guard !stopped else { return }
            if now.timeIntervalSince(item.createdAt) > PendingImageStore.maxAge { await drop(item); continue }
            switch deps.gate(item.productId) {
            case .gone: await drop(item); continue
            case .waiting: waiting = true; continue
            case .ready: break
            }
            let preview = deps.store.preview(item.productId)
            let outcome = await send(item)
            // 发的时候人又选了 / 拍了新的（同一个商品、同一个文件）：这一条的结果不再动暂存和预览，新的那条下一趟照常发
            guard let cur = deps.store.current(item.productId), cur.createdAt == item.createdAt, cur.token == item.token else { continue }
            switch outcome {
            case .sent(let ver):
                deps.store.remove(item.productId)
                await deps.succeeded(item.productId, ver, preview)
            case .keep: continue
            case .drop: await drop(item)
            case .notFound:
                var next = item
                next.notFound += 1
                if next.notFound >= 3 { await drop(item) } else { try? deps.store.update(next) }
            case .stopRound: return
            }
        }
        if waiting && kickIfWaiting { await deps.needSync() }
    }

    private func drop(_ item: PendingImage) async {
        deps.store.remove(item.productId)
        await deps.dropped(item.productId)
    }

    private func send(_ item: PendingImage, retried: Bool = false) async -> Outcome {
        guard let token = deps.token() else { return .stopRound }
        attempts += 1
        do {
            switch item.kind {
            case .select:
                guard let code = item.barcode, let cid = item.candidateId else { return .drop }
                return .sent(try await deps.select(item.productId, code, cid, token))
            case .photo:
                // 照片文件丢了或不像 JPEG、超了上限：发不出去，丢掉（不挡后面的）
                guard let jpeg = deps.store.payload(item.productId), jpeg.count <= APIClient.uploadMaxBytes,
                      ProductImageLoader.looksLikeJPEG(jpeg) else { return .drop }
                return .sent(try await deps.upload(item.productId, jpeg, token))
            }
        } catch let e as APIError {
            switch e {
            case .server(let status, let code, _, let retry):
                Self.logger.notice("换图没发成：\(status) \(code, privacy: .public)")
                switch status {
                case 401: return .stopRound
                case 404: return .notFound
                case 400, 403, 413: return .drop
                case 503 where !retried:
                    await deps.sleep(.seconds(min(max(retry ?? 2, 1), 5)))
                    return await send(item, retried: true)
                default: return .stopRound   // 429、5xx：这一趟先停
                }
            case .badResponse(0):
                return .drop   // 本机就判出发不了（条码、cid 不合规）：丢掉，不挡后面的
            case .transport, .redirected, .badResponse:
                return .stopRound
            }
        } catch {
            return .stopRound
        }
    }
}

/// 一个会话的换图（S22d）：界面这一侧。选了图 → 暂存（后台写盘）、先显示预览、让 `ImageUploader` 去发；
/// 发成功 → prime 缓存、预览记下版本、踢一趟同步把新的 `image_ver` 拉回来。由 `ProductImages` 持有，会话结束跟着 `shutdown`。
@MainActor
final class ImageChanges {
    let store: PendingImageStore
    let uploader: ImageUploader
    /// 取候选、发选图用（地址只用 `bases.current`，连不上退回默认地址）
    let api: APIClient
    let token: @Sendable () -> String?
    weak var images: ProductImages?
    private let relay: Relay
    /// 踢一趟同步（夹具里没有同步，为 nil）
    var kickSync: (() -> Void)?
    private var stopped = false

    init(store: PendingImageStore, gate: @escaping @Sendable (UUID) -> ImageGate, api: APIClient, token: @escaping @Sendable () -> String?) {
        self.store = store
        self.api = api
        self.token = token
        let relay = Relay()
        self.relay = relay
        uploader = ImageUploader(.init(
            store: store, gate: gate, token: token,
            select: { try await api.selectImage(productId: $0, barcode: $1, candidateId: $2, token: $3) },
            upload: { try await api.uploadImage(productId: $0, jpeg: $1, token: $2) },
            enabled: { await relay.enabled() },
            succeeded: { id, ver, data in await relay.succeeded(id, ver, data) },
            needSync: { await relay.needSync() },
            dropped: { id in await relay.dropped(id) }))
        relay.target = self
    }

    /// uploader 的回调转回主线程（uploader 建好之前 self 还没有）
    final class Relay: @unchecked Sendable {
        weak var target: ImageChanges?
        @MainActor func enabled() -> Bool { target.map { !$0.stopped && ($0.images?.enabled ?? false) } ?? false }
        @MainActor func succeeded(_ id: UUID, _ ver: Int, _ data: Data?) { target?.succeeded(id, ver, data) }
        @MainActor func needSync() { target?.kickSync?() }
        @MainActor func dropped(_ id: UUID) { target?.images?.dropPreview(productId: id) }
    }

    #if DEBUG
    /// 测试看：uploader 回调的中转
    var relayForTest: Relay { relay }
    #endif

    /// 正常启动：本机账本库做闸门（读不出来当「先等」）
    static func live(db: LocalDB, storeId: UUID, api: APIClient, token: @escaping @Sendable () -> String?) -> ImageChanges {
        ImageChanges(store: PendingImageStore(storeId: storeId), gate: { (try? db.imageGate(productId: $0)) ?? .waiting },
                     api: api, token: token)
    }

    /// 会话建立：删掉别的店留下的暂存，把还在的预览装回来，然后发一趟
    func start() {
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            store.removeOtherStores()
            let previews = store.all().compactMap { i in store.preview(i.productId).flatMap(UIImage.init(data:)).map { (i.productId, $0) } }
            await self?.restore(previews)
            await self?.flush()
        }
    }

    private func restore(_ previews: [(UUID, UIImage)]) {
        for (id, img) in previews { images?.setPreview(img, productId: id) }
    }

    /// 选了一张候选图：暂存（带缩图字节）、显示预览、去发
    func choose(productId: UUID, barcode: String, candidateId: String, thumbnail: Data?) {
        guard !stopped else { return }
        if let thumbnail, let img = UIImage(data: thumbnail) { images?.setPreview(img, productId: productId) }
        let item = PendingImage(kind: .select, productId: productId, barcode: barcode, candidateId: candidateId, createdAt: Date())
        enqueue(item, payload: nil, preview: thumbnail)
    }

    /// 拍了 / 从相册选了一张照片（已压好：上传件 ≤ 400 KB，预览 200px）：暂存、显示预览、去发。「重新拍照」就是再来一次
    func upload(productId: UUID, photo: CompressedPhoto) {
        guard !stopped else { return }
        if let img = UIImage(data: photo.preview) { images?.setPreview(img, productId: productId) }
        enqueue(PendingImage(kind: .photo, productId: productId, createdAt: Date()), payload: photo.upload, preview: photo.preview)
    }

    private func enqueue(_ item: PendingImage, payload: Data?, preview: Data?) {
        let uploader = uploader
        Task.detached(priority: .userInitiated) { await uploader.enqueue(item, payload: payload, preview: preview) }
    }

    /// 同步成功之后、会话建立时：发一趟（不踢同步）
    func flush() {
        guard !stopped else { return }
        let uploader = uploader
        Task { await uploader.flush(kickIfWaiting: false) }
    }

    private func succeeded(_ id: UUID, _ ver: Int, _ data: Data?) {
        guard !stopped else { return }
        if let data { images?.prime(data, productId: id, ver: ver) }
        images?.confirmPreview(productId: id, ver: ver)
        kickSync?()
    }

    /// 会话结束（退出、被踢、换身份）：停掉、这家店的暂存全删
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        let uploader = uploader
        Task.detached(priority: .utility) { await uploader.stopAndClear() }
    }
}
