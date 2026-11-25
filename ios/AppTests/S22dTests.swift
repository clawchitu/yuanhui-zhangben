import ImageIO
import ShopCore
import UIKit
import XCTest
@testable import YuanhuiZhangben

/// S22d 选商品图的 App 侧：暂存、闸门、重发、各状态码的处理、候选轮询、谁能看到入口（Fable 方案 2、5、6）
@MainActor
final class S22dTests: XCTestCase {
    var root: URL!
    let store = UUID()

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s22d-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func item(_ id: UUID = UUID(), cid: String = "0123456789abcdef", at: Date = Date()) -> PendingImage {
        PendingImage(kind: .select, productId: id, barcode: "6920152400319", candidateId: cid, createdAt: at)
    }

    /// 桩：记下每次 select，按脚本回结果
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var replies: [Result<Int, Error>] = []
        var calls: [(UUID, String, String, String)] = []
        var uploads: [(UUID, Data)] = []
        var gate: ImageGate = .ready
        var succeeded: [(UUID, Int, Data?)] = []
        var kicks = 0
        var sleeps: [Duration] = []
        var enabled = true
        func next() -> Result<Int, Error> { lock.withLock { replies.isEmpty ? .success(1) : replies.removeFirst() } }
    }

    func uploader(_ s: Script, store ps: PendingImageStore, now: Date = Date()) -> ImageUploader {
        ImageUploader(.init(
            store: ps, gate: { _ in s.lock.withLock { s.gate } }, token: { "tok" },
            select: { id, code, cid, tok in
                s.lock.withLock { s.calls.append((id, code, cid, tok)) }
                return try s.next().get()
            },
            upload: { id, jpeg, tok in
                s.lock.withLock { s.uploads.append((id, jpeg)) }
                return try s.next().get()
            },
            enabled: { s.lock.withLock { s.enabled } },
            succeeded: { id, v, d in s.lock.withLock { s.succeeded.append((id, v, d)) } },
            needSync: { s.lock.withLock { s.kicks += 1 } },
            now: { now }, sleep: { d in s.lock.withLock { s.sleeps.append(d) } }))
    }

    static func server(_ status: Int, retry: Int? = nil) -> Error {
        APIError.server(status: status, code: "x", lockedUntil: nil, retryAfterS: retry)
    }

    // MARK: 暂存

    /// 同一商品只留最后一次；图片字节跟着存；删除、整家店删除；别的店的目录在会话建立时删掉
    func testStoreKeepsLastPerProduct() throws {
        let ps = PendingImageStore(root: root, storeId: store)
        let id = UUID()
        try ps.put(item(id, cid: "0123456789abcdef"), payload: Data([1, 2, 3]))
        try ps.put(item(id, cid: "1111111111111111"), payload: Data([4]))
        XCTAssertEqual(ps.all().map(\.candidateId), ["1111111111111111"])
        XCTAssertEqual(ps.payload(id), Data([4]))
        let other = PendingImageStore(root: root, storeId: UUID())
        try other.put(item(), payload: nil)
        ps.removeOtherStores()
        XCTAssertEqual(other.all().count, 0, "别的店的暂存删掉")
        XCTAssertEqual(ps.all().count, 1)
        ps.remove(id)
        XCTAssertEqual(ps.all().count, 0)
        XCTAssertNil(ps.payload(id))
        try ps.put(item(), payload: nil)
        ps.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ps.dir.path))
    }

    /// 每家店最多 100 条，超了丢最旧的；坏文件当没有
    func testStoreTrimsOldestAndIgnoresGarbage() throws {
        let ps = PendingImageStore(root: root, storeId: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = UUID()
        try ps.put(item(first, at: t0), payload: nil)
        for i in 1...PendingImageStore.maxItems { try ps.put(item(at: t0.addingTimeInterval(TimeInterval(i))), payload: nil) }
        let all = ps.all()
        XCTAssertEqual(all.count, PendingImageStore.maxItems)
        XCTAssertFalse(all.contains { $0.productId == first }, "最旧的丢掉")
        try Data("坏".utf8).write(to: ps.dir.appendingPathComponent("\(UUID().uuidString.lowercased()).json"))
        XCTAssertEqual(ps.all().count, PendingImageStore.maxItems)
    }

    // MARK: 闸门和重发

    /// 登记没确认：不发；只有暂存当下那一趟踢同步，同步之后的那趟不踢（不会一趟接一趟地同步）；确认后发一次、删掉、回调带缩图字节
    func testGateHoldsUntilUpsertConfirmed() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let id = UUID()
        try ps.put(item(id), preview: Data([9]))
        s.gate = .waiting
        let u = uploader(s, store: ps)
        await u.flush(kickIfWaiting: true)
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 0, "登记没确认：一个 select 都不发")
        XCTAssertEqual(s.kicks, 1, "只踢一次同步")
        s.gate = .ready
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 1)
        XCTAssertEqual(s.calls.first?.0, id)
        XCTAssertEqual(s.calls.first?.2, "0123456789abcdef")
        XCTAssertEqual(s.succeeded.first?.1, 1)
        XCTAssertEqual(s.succeeded.first?.2, Data([9]), "成功回调带候选缩图（prime 用）")
        XCTAssertEqual(ps.all().count, 0, "发成功删掉")
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 1, "不重发")
    }

    /// 登记被拒、本机没这个商品：丢掉，不发
    func testGoneDrops() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        try ps.put(item(), payload: nil)
        s.gate = .gone
        await uploader(s, store: ps).flush(kickIfWaiting: true)
        XCTAssertEqual(s.calls.count, 0)
        XCTAssertEqual(ps.all().count, 0)
        XCTAssertEqual(s.kicks, 0)
    }

    /// 404：能发之后累计 3 次才丢；401 / 429 / 5xx / 连不上：留着，本趟停（后面那条也不发）
    func testNotFoundThreeTimesThenDrop() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        try ps.put(item(), payload: nil)
        let u = uploader(s, store: ps)
        s.replies = [.failure(Self.server(404)), .failure(Self.server(404))]
        await u.flush(kickIfWaiting: false)
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(ps.all().first?.notFound, 2, "两次 404 还留着")
        s.replies = [.failure(Self.server(404))]
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(ps.all().count, 0, "第三次 404 丢掉")
        XCTAssertEqual(s.succeeded.count, 0)
    }

    func testTransientErrorsKeepAndStopRound() async throws {
        for e in [Self.server(401), Self.server(429), Self.server(500), APIError.transport("x"), APIError.redirected(307)] {
            let ps = PendingImageStore(root: root, storeId: UUID()), s = Script()
            let t0 = Date()
            try ps.put(item(at: t0), payload: nil)
            try ps.put(item(at: t0.addingTimeInterval(1)), payload: nil)
            s.replies = [.failure(e)]
            await uploader(s, store: ps).flush(kickIfWaiting: false)
            XCTAssertEqual(s.calls.count, 1, "\(e)：本趟停，第二条不发")
            XCTAssertEqual(ps.all().count, 2, "\(e)：都留着")
            XCTAssertEqual(ps.all().first?.notFound, 0)
        }
    }

    /// 400、403、413：丢掉，接着发下一条
    func testPermanentErrorsDrop() async throws {
        for status in [400, 403, 413] {
            let ps = PendingImageStore(root: root, storeId: UUID()), s = Script()
            let t0 = Date()
            try ps.put(item(at: t0), payload: nil)
            try ps.put(item(at: t0.addingTimeInterval(1)), payload: nil)
            s.replies = [.failure(Self.server(status)), .success(3)]
            await uploader(s, store: ps).flush(kickIfWaiting: false)
            XCTAssertEqual(s.calls.count, 2, "\(status)")
            XCTAssertEqual(ps.all().count, 0, "\(status)：第一条丢掉、第二条发成功")
            XCTAssertEqual(s.succeeded.map(\.1), [3])
        }
    }

    /// 503（店忙）：等 retry_after_s（最多 5 秒）本趟再试一次；再忙就留到下一趟
    func testBusyRetriesOnce() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        try ps.put(item(), payload: nil)
        s.replies = [.failure(Self.server(503, retry: 2)), .success(5)]
        let u = uploader(s, store: ps)
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 2)
        XCTAssertEqual(s.sleeps, [.seconds(2)])
        XCTAssertEqual(s.succeeded.map(\.1), [5])
        try ps.put(item(), payload: nil)
        s.replies = [.failure(Self.server(503, retry: 60)), .failure(Self.server(503, retry: 60))]
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.sleeps.last, .seconds(5), "最多等 5 秒")
        XCTAssertEqual(ps.all().count, 1, "两次都忙：留着")
    }

    /// 放了 14 天：丢掉；开关关：一条都不发、都留着
    func testExpiredAndSwitchOff() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let now = Date()
        try ps.put(item(at: now.addingTimeInterval(-15 * 86_400)), payload: nil)
        try ps.put(item(at: now), payload: nil)
        s.enabled = false
        let u = uploader(s, store: ps, now: now)
        await u.flush(kickIfWaiting: true)
        XCTAssertEqual(s.calls.count, 0, "开关关：不发")
        XCTAssertEqual(ps.all().count, 2)
        s.enabled = true
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 1, "过期的不发")
        XCTAssertEqual(ps.all().count, 0)
    }

    /// 照片：等登记确认后 PUT 暂存的上传件；成功回调带 200px 预览；同一商品后来的照片顶掉先前的选图；照片文件坏了丢掉不挡后面的
    func testPhotoUploadsPayloadAndReplacesSelect() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let id = UUID(), jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]), preview = Data([0xFF, 0xD8, 7])
        try ps.put(item(id), preview: Data([9]))
        try ps.put(PendingImage(kind: .photo, productId: id, createdAt: Date()), payload: jpeg, preview: preview)
        let bad = UUID()
        try ps.put(PendingImage(kind: .photo, productId: bad, createdAt: Date().addingTimeInterval(-1)), payload: Data("坏".utf8), preview: nil)
        s.replies = [.success(4)]
        await uploader(s, store: ps).flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 0, "照片顶掉了选图：不 select")
        XCTAssertEqual(s.uploads.map(\.0), [id], "坏照片不发")
        XCTAssertEqual(s.uploads.first?.1, jpeg)
        XCTAssertEqual(s.succeeded.first?.1, 4)
        XCTAssertEqual(s.succeeded.first?.2, preview, "prime 用 200px 预览")
        XCTAssertEqual(ps.all().count, 0, "成功的删掉、坏的丢掉")
    }

    /// 照片也走闸门和重发：登记没确认不 PUT；确认后 PUT 碰上临时错误（5xx、连不上）照片留着，下一趟发同样的字节
    func testPhotoWaitsForUpsertAndResendsAfterError() async throws {
        for e in [Self.server(500), APIError.transport("x")] {
            let ps = PendingImageStore(root: root, storeId: UUID()), s = Script()
            let id = UUID(), jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6]), preview = Data([0xFF, 0xD8, 8])
            try ps.put(PendingImage(kind: .photo, productId: id, createdAt: Date()), payload: jpeg, preview: preview)
            let u = uploader(s, store: ps)
            s.gate = .waiting
            await u.flush(kickIfWaiting: true)
            XCTAssertEqual(s.uploads.count, 0, "\(e)：登记没确认，不 PUT")
            XCTAssertEqual(s.kicks, 1)
            s.gate = .ready
            s.replies = [.failure(e)]
            await u.flush(kickIfWaiting: false)
            XCTAssertEqual(s.uploads.count, 1)
            XCTAssertEqual(ps.current(id)?.kind, .photo, "\(e)：临时错误，照片留着")
            XCTAssertEqual(ps.payload(id), jpeg)
            XCTAssertEqual(s.succeeded.count, 0)
            await u.flush(kickIfWaiting: false)
            XCTAssertEqual(s.uploads.map(\.1), [jpeg, jpeg], "\(e)：重发同样的字节")
            XCTAssertEqual(s.succeeded.first?.2, preview)
            XCTAssertNil(ps.current(id), "发成功删掉")
        }
    }

    /// ① 存下的待发选图（json 里没有 token、缩图在 `.jpg`）：升级后照常读出来、照常发、成功时带缩图
    func testEntriesFromFirstVersionStillWork() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let id = UUID()
        try ps.put(item(id), payload: Data([0xFF, 0xD8, 4]))
        let f = ps.dir.appendingPathComponent("\(id.uuidString.lowercased()).json")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
        obj.removeValue(forKey: "token")
        try JSONSerialization.data(withJSONObject: obj).write(to: f)
        XCTAssertNil(ps.current(id)?.token)
        XCTAssertEqual(ps.preview(id), Data([0xFF, 0xD8, 4]), "没有 .thumb.jpg 时读 .jpg 里的缩图")
        await uploader(s, store: ps).flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.count, 1)
        XCTAssertEqual(s.succeeded.first?.2, Data([0xFF, 0xD8, 4]))
        XCTAssertNil(ps.current(id))
    }

    /// 旧照片还在上传时人又选了新图（同一秒里）：旧的成功后不删新的、不拿旧版本记预览；新的下一趟照常发
    func testNewerChoiceSurvivesInFlightUpload() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let id = UUID(), t0 = Date()
        try ps.put(PendingImage(kind: .photo, productId: id, createdAt: t0), payload: Data([0xFF, 0xD8, 0xFF, 0xE0, 1]), preview: Data([0xFF, 0xD8, 2]))
        let u = ImageUploader(.init(
            store: ps, gate: { _ in .ready }, token: { "tok" },
            select: { _, _, cid, _ in s.lock.withLock { s.calls.append((id, "", cid, "")) }; return 2 },
            upload: { _, _, _ in
                // 上传途中：同一商品又选了一张候选图
                try ps.put(PendingImage(kind: .select, productId: id, barcode: "6920152400319", candidateId: "1111111111111111",
                                        createdAt: t0), preview: Data([0xFF, 0xD8, 3]))   // 同一秒（存盘只到秒）
                return 1
            },
            enabled: { true }, succeeded: { i, v, d in s.lock.withLock { s.succeeded.append((i, v, d)) } }, needSync: {}))
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(ps.current(id)?.kind, .select, "新选的图还在")
        XCTAssertEqual(s.succeeded.count, 0, "旧照片的结果不记预览")
        await u.flush(kickIfWaiting: false)
        XCTAssertEqual(s.calls.map(\.2), ["1111111111111111"], "新的下一趟发出去")
        XCTAssertEqual(s.succeeded.first?.2, Data([0xFF, 0xD8, 3]))
        XCTAssertNil(ps.current(id))
    }

    /// 压缩：竖拍 4032×3024（方向 .right）的大图 → 768×1024（方向烘进像素）、JPEG、≤ 400 KB；预览长边 200；小图不放大
    func testCompressorMeetsSpec() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let noisy = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: format).image { c in
            for y in stride(from: 0, to: 3024, by: 8) { for x in stride(from: 0, to: 4032, by: 8) {
                UIColor(white: CGFloat((x * 7 + y * 13) % 255) / 255, alpha: 1).setFill(); c.fill(CGRect(x: x, y: y, width: 8, height: 8))
            } }
        }
        let shot = UIImage(cgImage: noisy.cgImage!, scale: 1, orientation: .right)
        let p = try XCTUnwrap(PhotoCompressor.compress(shot))
        XCTAssertLessThanOrEqual(p.upload.count, PhotoCompressor.maxBytes)
        let up = try XCTUnwrap(UIImage(data: p.upload))
        XCTAssertEqual(up.size, CGSize(width: 768, height: 1024))
        XCTAssertEqual(up.imageOrientation, .up)
        let pv = try XCTUnwrap(UIImage(data: p.preview))
        XCTAssertEqual(max(pv.size.width, pv.size.height), 200)
        let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        XCTAssertEqual(UIImage(data: try XCTUnwrap(PhotoCompressor.compress(small)).upload)?.size, CGSize(width: 300, height: 200), "不放大")
    }

    /// 方向真的烘进像素：原始像素上红下蓝、方向 `.right`（竖拿手机拍）→ 转正后应是左蓝右红（不是只把宽高对调、把图压扁）。
    /// 相册那条路（JPEG 带 EXIF 方向 6）走 `downsample` 也一样
    func testCompressorBakesOrientation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 600))
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 600, width: 1600, height: 600))
        }.cgImage!
        func check(_ upload: Data, _ what: String) throws {
            let cg = try XCTUnwrap(UIImage(data: upload)?.cgImage, what)
            XCTAssertEqual(CGSize(width: cg.width, height: cg.height), CGSize(width: 768, height: 1024), what)
            let left = try pixel(cg, x: 100, y: 200), right = try pixel(cg, x: 668, y: 200)
            XCTAssertTrue(left.b > 200 && left.r < 60, "\(what)：左边应是蓝的，实际 \(left)")
            XCTAssertTrue(right.r > 200 && right.b < 60, "\(what)：右边应是红的，实际 \(right)")
        }
        try check(try XCTUnwrap(PhotoCompressor.compress(UIImage(cgImage: raw, scale: 1, orientation: .right))).upload, "拍照")
        let jpeg = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, raw, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let album = try XCTUnwrap(PhotoCompressor.downsample(jpeg as Data))
        try check(try XCTUnwrap(PhotoCompressor.compress(album)).upload, "相册")
    }

    /// 读一个像素（RGBA8）
    func pixel(_ cg: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    // MARK: 闸门接真的本机库

    /// 真的登记 → outbox 里 product_upsert 没确认 → 闸门「先等」；`recordResults` 确认 → 「能发」；被拒 → 「不用发了」
    func testGateWithRealOutbox() throws {
        for final in [OutboxItem.Status.applied, .rejected] {
            let db = try LocalDB.inMemory()
            try db.beginSession(try LocalSession(deviceId: UUID(), storeId: store, role: .family, tokenRef: "t", storeName: "店", deviceLabel: "机"))
            let conv = try db.registerProduct(try NewProduct(barcode: "6920152400319", name: "茶", priceFen: Fen(350)))
            XCTAssertEqual(try db.imageGate(productId: conv.product.id), .waiting)
            XCTAssertEqual(try db.imageGate(productId: UUID()), .gone, "本机没有这个商品")
            let op = try XCTUnwrap(try db.pendingOps().first { $0.type == .productUpsert })
            try db.recordResults([try OpResult(id: op.id, status: final)], storeId: store)
            XCTAssertEqual(try db.imageGate(productId: conv.product.id), final == .applied ? .ready : .gone, "\(final)")
        }
    }

    // MARK: 谁有入口

    /// 家用有换图；收银员没有；演示店（审核号会话）没有
    func testOnlyFamilyNonDemoGetsChanges() throws {
        let suite = "S22dTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let bases = APIBaseStore(defaultBase: "http://localhost:1", policy: APIEnvironment.policy, defaults: defaults)!
        let services = AppServices(api: APIClient(bases: bases), tokens: MemoryTokenStore(), defaults: defaults)
        func make(_ role: Role, demo: Bool) throws -> Bool {
            let db = try LocalDB.inMemory()
            let s = try LocalSession(deviceId: UUID(), storeId: UUID(), role: role, tokenRef: "t", storeName: "店", deviceLabel: "机")
            try db.beginSession(s)
            if demo { defaults.set(s.deviceId.uuidString, forKey: AuthDefaults.demoDeviceId) } else { defaults.removeObject(forKey: AuthDefaults.demoDeviceId) }
            let images = ProductImages.live(db: db, session: s, services: services, syncBusy: { false })
            defer { images.shutdown() }
            return images.changesForTest != nil
        }
        XCTAssertTrue(try make(.family, demo: false))
        XCTAssertFalse(try make(.cashier, demo: false))
        XCTAssertFalse(try make(.review, demo: true))
        XCTAssertFalse(try make(.family, demo: true))
    }

    /// S22d-10：会话结束（`ProductImages.shutdown`）：这家店的暂存目录删掉，uploader 停住，之后再 flush 也不发
    func testShutdownDropsPendingAndStops() async throws {
        let ps = PendingImageStore(root: root, storeId: store), s = Script()
        let u = uploader(s, store: ps)
        let bases = APIBaseStore(defaultBase: "http://localhost:1", policy: APIEnvironment.policy, defaults: UserDefaults(suiteName: "S22dTests-shutdown")!)!
        let changes = ImageChanges(store: ps, gate: { _ in .ready }, api: APIClient(bases: bases), token: { "tok" })
        let images = ProductImages(db: nil, disk: ProductImageDisk(root: root.appendingPathComponent("disk"), storeId: store), enabled: true,
                                   blocked: false, base: { URL(string: "http://localhost:1")! }, token: { "tok" }, syncBusy: { false })
        images.changes = changes
        changes.images = images
        try ps.put(item(), payload: Data([1]))
        changes.choose(productId: UUID(), barcode: "6920152400319", candidateId: "1111111111111111", thumbnail: nil)
        images.shutdown()
        XCTAssertNil(images.changes)
        await waitUntil("暂存目录删掉") { !FileManager.default.fileExists(atPath: ps.dir.path) }
        await changes.uploader.flush(kickIfWaiting: true)
        let attempts = await changes.uploader.attempts
        XCTAssertEqual(attempts, 0, "停住了：一个请求都不发")
        _ = u
    }

    /// S22d-11：发成功 → prime 这张缩图、预览记下版本（商品版本追上后仍显示；别处换了更高版本就不用预览）；丢掉 → 预览撤掉
    func testSucceededPrimesAndConfirmsPreview() async throws {
        let ps = PendingImageStore(root: root, storeId: store)
        let bases = APIBaseStore(defaultBase: "http://localhost:1", policy: APIEnvironment.policy, defaults: UserDefaults(suiteName: "S22dTests-ok")!)!
        let changes = ImageChanges(store: ps, gate: { _ in .ready }, api: APIClient(bases: bases), token: { "tok" })
        let images = ProductImages(db: nil, disk: ProductImageDisk(root: root.appendingPathComponent("disk"), storeId: store), enabled: true,
                                   blocked: false, base: { URL(string: "http://localhost:1")! }, token: { "tok" }, syncBusy: { false })
        images.changes = changes
        changes.images = images
        var kicks = 0
        changes.kickSync = { kicks += 1 }
        let id = UUID(), img = try XCTUnwrap(UIImage(data: Self.jpeg))
        images.setPreview(img, productId: id)
        XCTAssertNotNil(images.preview(ImageKey(id, 0)), "还没传上去：显示预览")
        await changes.relayForTest.succeeded(id, 2, Self.jpeg)
        XCTAssertEqual(kicks, 1, "成功后踢一趟同步拉回新版本")
        XCTAssertNotNil(images.preview(ImageKey(id, 2)), "版本追上了：同一张图")
        XCTAssertNil(images.preview(ImageKey(id, 3)), "别处又换了：不用预览")
        await waitUntil("prime 落盘") { images.loader.disk.best(ImageKey(id, 2))?.0 == ImageKey(id, 2) }
        let other = UUID()
        images.setPreview(img, productId: other)
        images.dropPreview(productId: other)
        XCTAssertNil(images.preview(ImageKey(other, 0)), "丢掉的撤掉预览")
        images.shutdown()
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ ok: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await ok() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等不到：\(what)")
    }

    // MARK: 候选轮询

    final class States: @unchecked Sendable {
        let lock = NSLock()
        var list: [ImageCandidates]
        var calls = 0
        var images: [String] = []
        var failImage: Set<String> = []
        init(_ l: [ImageCandidates]) { list = l }
        func next() -> ImageCandidates { lock.withLock { calls += 1; return list.count > 1 ? list.removeFirst() : list[0] } }
    }

    nonisolated static let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { c in
        UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }.jpegData(compressionQuality: 0.8)!

    func choice(_ s: States) -> ImageChoiceModel {
        let m = ImageChoiceModel(barcode: "6920152400319",
                                 fetchState: { _ in s.next() },
                                 fetchImage: { _, cid in
                                     s.lock.withLock { s.images.append(cid) }
                                     if s.lock.withLock({ s.failImage.contains(cid) }) { throw APIError.server(status: 404, code: "x", lockedUntil: nil, retryAfterS: nil) }
                                     return Self.jpeg
                                 })
        m.pollInterval = .milliseconds(50)
        m.pollLimit = .milliseconds(400)
        return m
    }

    /// ready：不轮询；拿不到缩图的那张不给选；默认选第一张能用的
    func testReadyNoPollAndSkipsBrokenThumb() async {
        let s = States([ImageCandidates(state: .ready, ids: [])])
        s.failImage = ["0123456789abcdef"]
        let m = choice(s)
        await m.run(initial: ImageCandidates(state: .ready, ids: ["0123456789abcdef", "1111111111111111"]))
        XCTAssertTrue(m.settled)
        XCTAssertEqual(s.calls, 0, "ready：不再问")
        XCTAssertEqual(m.usable, ["1111111111111111"])
        XCTAssertEqual(m.selected, "1111111111111111")
    }

    /// pending → ready：按间隔问，拿到 ready 就停
    func testPendingPollsUntilReady() async {
        let s = States([ImageCandidates(state: .pending, ids: ["0123456789abcdef"]),
                        ImageCandidates(state: .ready, ids: ["0123456789abcdef", "1111111111111111"])])
        let m = choice(s)
        await m.run(initial: ImageCandidates(state: .pending, ids: []))
        XCTAssertEqual(s.calls, 2)
        XCTAssertEqual(m.usable, ["0123456789abcdef", "1111111111111111"])
    }

    /// 一直 pending：到时限就停，有几张算几张；查码没带回候选（nil）先问一次
    func testPendingStopsAtLimit() async {
        let s = States([ImageCandidates(state: .pending, ids: ["0123456789abcdef"])])
        let m = choice(s)
        let start = ContinuousClock.now
        await m.run(initial: nil)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertGreaterThanOrEqual(s.calls, 4)
        XCTAssertLessThanOrEqual(s.calls, 11)
        XCTAssertEqual(m.usable, ["0123456789abcdef"])
        XCTAssertTrue(m.settled)
    }

    /// none（含没网）：不问、不下图
    func testNoneDoesNothing() async {
        let s = States([ImageCandidates(state: .ready, ids: ["0123456789abcdef"])])
        let m = choice(s)
        await m.run(initial: .empty)
        XCTAssertEqual(s.calls, 0)
        XCTAssertEqual(s.images, [])
        XCTAssertEqual(m.usable, [])
    }
}

extension ProductImages {
    /// 测试看：这个会话有没有换图
    var changesForTest: ImageChanges? { changes }
}
