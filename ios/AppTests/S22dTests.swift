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
        try ps.put(item(id), payload: Data([9]))
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
