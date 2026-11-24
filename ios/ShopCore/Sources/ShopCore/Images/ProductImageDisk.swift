import Foundation

/// 一张商品图：商品 id + `image_ver`（S22c）
public struct ImageKey: Hashable, Sendable, CustomStringConvertible {
    public let productId: UUID
    public let ver: Int
    public init(_ productId: UUID, _ ver: Int) { self.productId = productId; self.ver = ver }
    /// 文件名主干 `<productId>_<imageVer>`
    public var description: String { "\(productId.uuidString.lowercased())_\(ver)" }

    init?(fileName: String) {
        guard fileName.hasSuffix(".jpg") else { return nil }
        let stem = fileName.dropLast(4)
        guard let us = stem.lastIndex(of: "_"), let id = UUID(uuidString: String(stem[..<us])),
              let v = Int(stem[stem.index(after: us)...]), v > 0 else { return nil }
        self.init(id, v)
    }
}

/// 商品图的磁盘缓存（S22c，Fable 裁定 4）：`Caches/product-images/<storeId>/<productId>_<imageVer>.jpg`。
///
/// - 写：`Data.write(.atomic)`（临时文件 + 改名），文件保护 `completeUntilFirstUserAuthentication`；新版落盘后才删这个商品的旧版。
/// - 上限 100 MB，超了按修改时间从旧到新删。
/// - 所有方法都做磁盘 IO：**不许在主线程调**（调用方放到后台任务 / 下载器 actor 里）。
public final class ProductImageDisk: Sendable {
    public let root: URL
    public let storeId: UUID
    public let limitBytes: Int
    private let lock = NSLock()

    public static let defaultLimitBytes = 100 * 1024 * 1024

    /// `Caches/product-images`
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("product-images", isDirectory: true)
    }

    public init(root: URL = ProductImageDisk.defaultRoot(), storeId: UUID, limitBytes: Int = ProductImageDisk.defaultLimitBytes) {
        self.root = root
        self.storeId = storeId
        self.limitBytes = limitBytes
    }

    public var directory: URL { root.appendingPathComponent(storeId.uuidString.lowercased(), isDirectory: true) }

    func file(_ k: ImageKey) -> URL { directory.appendingPathComponent("\(k).jpg") }

    private var fm: FileManager { .default }

    /// 这个店目录下的全部图（文件名认不出来的不算）
    public func keys() -> [ImageKey] {
        lock.withLock { unlockedKeys() }
    }

    private func unlockedKeys() -> [ImageKey] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap(ImageKey.init(fileName:))
    }

    public func has(_ k: ImageKey) -> Bool { lock.withLock { fm.fileExists(atPath: file(k).path) } }

    public func read(_ k: ImageKey) -> Data? { lock.withLock { try? Data(contentsOf: file(k)) } }

    /// 正好这一版；没有就取本机有的、不比它新的最新一版（新版还没下来时先显示旧图）
    public func best(_ k: ImageKey) -> (ImageKey, Data)? {
        lock.withLock {
            if let d = try? Data(contentsOf: file(k)) { return (k, d) }
            let older = unlockedKeys().filter { $0.productId == k.productId && $0.ver < k.ver }.max { $0.ver < $1.ver }
            guard let o = older, let d = try? Data(contentsOf: file(o)) else { return nil }
            return (o, d)
        }
    }

    /// 原子写入，然后删这个商品的其他版本，再按上限淘汰；返回因为容量被淘汰掉的图
    @discardableResult
    public func write(_ data: Data, for k: ImageKey) throws -> [ImageKey] {
        try lock.withLock {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: file(k), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file(k), options: [.atomic])
            #endif
            for o in unlockedKeys() where o.productId == k.productId && o != k {
                try? fm.removeItem(at: file(o))
            }
            return evict(keeping: k)
        }
    }

    /// 超过上限：按修改时间从旧到新删，刚写的那张不删
    private func evict(keeping k: ImageKey) -> [ImageKey] {
        let urls = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
        var items = urls.map { u -> (URL, Int, Date) in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        guard total > limitBytes else { return [] }
        items.sort { $0.2 < $1.2 }
        let keep = file(k).lastPathComponent
        var gone: [ImageKey] = []
        for (u, size, _) in items where total > limitBytes && u.lastPathComponent != keep {
            try? fm.removeItem(at: u)
            total -= size
            if let e = ImageKey(fileName: u.lastPathComponent) { gone.append(e) }
        }
        return gone
    }

    /// 只留这些商品的图（每轮预取后：不在当前商品表、已归档、`image_ver` 变 0 的都删）
    public func prune(keeping ids: Set<UUID>) {
        lock.withLock {
            for k in unlockedKeys() where !ids.contains(k.productId) { try? fm.removeItem(at: file(k)) }
        }
    }

    /// 删整个 `product-images` 目录（开关关、会话变化，T11 / Fable 裁定 5、6）
    public func removeAll() {
        lock.withLock { try? fm.removeItem(at: root) }
    }

    /// 启动时：删不是当前会话店的子目录
    public func removeOtherStores() {
        lock.withLock {
            let mine = storeId.uuidString.lowercased()
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != mine {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// 店目录占用的字节数（测试看）
    public func totalBytes() -> Int {
        lock.withLock {
            ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }
}
