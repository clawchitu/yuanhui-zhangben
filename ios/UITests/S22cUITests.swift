import Foundation
import Network
import UIKit
import XCTest

/// S22c 界面验收（plan-v2 §8 S22c；Fable 裁定 9）：卖出页夹具 + 假扫码连扫 50 次，商品图从测试进程里的桩服务器取。
/// - 延迟组：每张图 10 秒才回；对照组：不开商品图。两组都要 50 次全进、主线程最长停顿 < 200 ms（`-uiFrameProbe`，CADisplayLink）
/// - 图片请求的主机是 `-uiImages` 给的地址（夹具里的「自家服务器」），同时在飞不超过 2 个
/// - 收银员身份能看到图；开关关显示首字、一个请求都不发
@MainActor
final class S22cUITests: XCTestCase {
    private var stub: ImageStub!
    /// 演示数据里单件码（一码一件），轮着扫
    static let codes = ["6901234500011", "6901035600016", "6902514300011", "6925303770013", "6921168509256"]
    static let stallLimitMs = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try ImageStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func probe(_ app: XCUIApplication, _ id: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in el(app, id).label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// 不碰界面地等（查无障碍树会占 App 的主线程，量卡顿期间不查）
    private func idle(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func launch(images: Bool, off: Bool = false, prefetch: Bool = false, role: String = "family", codes: [String], gap: Double = 0.3) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "on", "-uiRoute", "sell", "-uiProbe", "-uiFrameProbe",
                    "-uiScan", codes.joined(separator: ","), "-uiScanGap", String(gap), "-uiScanDelay", "2", "-uiAutoCommit", "-uiHoldDone"]
        if images { args += ["-uiImages", "http://localhost:\(stub.port)"] }
        if off { args.append("-uiImagesOff") }
        if prefetch { args.append("-uiImagesPrefetch") }
        app.launchArguments = args
        app.launch()
        return app
    }

    struct Run { let maxGapMs: Int; let frames: Int; let scanned: Int; let batches: Int }

    /// 连扫 50 次、自动记账：等量完（期间不查界面），返回主线程最长停顿和记进去的件数
    private func scanFifty(images: Bool, delay: TimeInterval, prefetch: Bool = false) -> Run {
        stub.delay = delay
        let codes = (0..<50).map { Self.codes[$0 % Self.codes.count] }
        let app = launch(images: images, prefetch: prefetch, codes: codes)
        XCTAssertTrue(el(app, "debug.images").waitForExistence(timeout: 15))
        idle(2 + 50 * 0.3 + 2)   // 开页等 2 秒 + 50 码 × 0.3 秒 + 余量
        var p = probe(app, "debug.images")
        let end = Date().addingTimeInterval(20)
        while p["frames"] != "done", Date() < end { idle(0.5); p = probe(app, "debug.images") }
        XCTAssertEqual(p["frames"], "done", "假扫码喂完了")
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 10), "50 次扫完记好了")
        let ledger = probe(app, "debug.ledger")
        let qty = (ledger["lastQty"] ?? "").split(separator: "|").compactMap { $0.split(separator: ":").last.flatMap { Int($0) } }.reduce(0, +)
        let run = Run(maxGapMs: Int(p["maxGapMs"] ?? "") ?? -1, frames: Int(p["frameCount"] ?? "") ?? 0, scanned: qty,
                      batches: Int(ledger["batches"] ?? "") ?? -1)
        print("S22c 实测（images=\(images), delay=\(delay)s）：maxGapMs=\(run.maxGapMs) frames=\(run.frames) 件数=\(run.scanned) 笔=\(run.batches) 图片请求=\(stub.requests.count) 最大在飞=\(stub.maxInFlight)")
        app.terminate()
        return run
    }

    /// 延迟组：每张图 10 秒才回（启动就预取一轮，再加上价签按需插队），连扫 50 次不卡、50 次全进
    func testFiftyScansWithTenSecondImageDelay() {
        let r = scanFifty(images: true, delay: 10, prefetch: true)
        XCTAssertEqual(r.scanned, 50, "50 次全进")
        XCTAssertEqual(r.batches, 1)
        XCTAssertGreaterThan(r.frames, 100)
        XCTAssertGreaterThanOrEqual(r.maxGapMs, 0)
        XCTAssertLessThan(r.maxGapMs, Self.stallLimitMs, "主线程最长停顿 \(r.maxGapMs) ms")
        XCTAssertGreaterThan(stub.requests.count, 0, "确实去要图了")
        XCTAssertLessThanOrEqual(stub.maxInFlight, 2, "同时在飞不超过 2 个")
        XCTAssertEqual(Set(stub.requests.map(\.host)), ["localhost:\(stub.port)"], "请求的主机是自家服务器（夹具里的地址）")
        XCTAssertTrue(stub.requests.allSatisfy { $0.path.hasPrefix("/v1/images/") && $0.query.hasPrefix("v=") && $0.auth == "Bearer fixture-token" })
    }

    /// 对照组：不开商品图，同样连扫 50 次
    func testFiftyScansControlWithoutImages() {
        let r = scanFifty(images: false, delay: 0)
        XCTAssertEqual(r.scanned, 50)
        XCTAssertEqual(r.batches, 1)
        XCTAssertLessThan(r.maxGapMs, Self.stallLimitMs, "主线程最长停顿 \(r.maxGapMs) ms")
        XCTAssertEqual(stub.requests.count, 0)
    }

    /// 图片服务器出错（500）时连扫同样不受影响
    func testFiftyScansWhileImagesFail() {
        stub.status = 500
        let r = scanFifty(images: true, delay: 0)
        XCTAssertEqual(r.scanned, 50)
        XCTAssertLessThan(r.maxGapMs, Self.stallLimitMs, "主线程最长停顿 \(r.maxGapMs) ms")
    }

    private func waitShown(_ app: XCUIApplication, _ n: Int, timeout: TimeInterval = 15) -> [String: String] {
        let end = Date().addingTimeInterval(timeout)
        var p = probe(app, "debug.images")
        while Int(p["shown"] ?? "") != n, Date() < end { idle(0.3); p = probe(app, "debug.images") }
        return p
    }

    /// 收银员形态同样能看到图（价签上的 Thumb 显示真图）
    func testCashierSeesProductImage() {
        let app = launch(images: true, role: "cashier", codes: [Self.codes[4]])
        let p = waitShown(app, 1)
        XCTAssertEqual(p["shown"], "1", "收银员价签上显示了真图：\(p)")
        XCTAssertEqual(p["enabled"], "1")
        XCTAssertEqual(stub.requests.count, 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "S22c 收银员看到商品图"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 开关关：显示首字，一个请求都不发
    func testSwitchOffShowsInitial() {
        let app = launch(images: true, off: true, codes: [Self.codes[4]])
        XCTAssertTrue(el(app, "debug.images").waitForExistence(timeout: 15))
        idle(5)
        let p = probe(app, "debug.images")
        XCTAssertEqual(p["shown"], "0", "开关关：价签显示首字")
        XCTAssertEqual(p["enabled"], "0")
        XCTAssertEqual(stub.requests.count, 0)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "S22c 开关关显示首字"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 服务器说没图（404）：显示首字
    func testMissingImageShowsInitial() {
        stub.status = 404
        let app = launch(images: true, codes: [Self.codes[4]])
        XCTAssertTrue(el(app, "debug.images").waitForExistence(timeout: 15))
        idle(5)
        XCTAssertEqual(probe(app, "debug.images")["shown"], "0")
        XCTAssertEqual(stub.requests.count, 1)
    }
}

/// 只回商品图的极简 HTTP/1.1 桩（一个连接一个请求）。可设延迟、状态码；记下主机头、路径、令牌、同时在飞的最大数
final class ImageStub: @unchecked Sendable {
    struct Request { let host: String; let path: String; let query: String; let auth: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "s22c-image-stub", attributes: .concurrent)
    private let lock = NSLock()
    private var log: [Request] = []
    private var inFlight = 0
    private var maxInFlightValue = 0
    private var delayValue: TimeInterval = 0
    private var statusValue = 200
    static let jpeg: Data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { c in
        UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        UIColor.white.setFill(); c.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
    }.jpegData(compressionQuality: 0.8)!

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() throws -> ImageStub {
        let s = try ImageStub()
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ImageStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
    var delay: TimeInterval { get { lock.withLock { delayValue } } set { lock.withLock { delayValue = newValue } } }
    var status: Int { get { lock.withLock { statusValue } } set { lock.withLock { statusValue = newValue } } }
    var requests: [Request] { lock.withLock { log } }
    var maxInFlight: Int { lock.withLock { maxInFlightValue } }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: b[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil { c.cancel() } else { self.receive(c, b) }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        func header(_ n: String) -> String {
            lines.dropFirst().first { $0.lowercased().hasPrefix(n + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let req = Request(host: header("host"), path: parts.first ?? "", query: parts.count > 1 ? parts[1] : "", auth: header("authorization"))
        let (delay, status) = lock.withLock { () -> (TimeInterval, Int) in
            log.append(req); inFlight += 1; maxInFlightValue = max(maxInFlightValue, inFlight)
            return (delayValue, statusValue)
        }
        let v = req.query.split(separator: "=").last.map(String.init) ?? "0"
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            lock.withLock { inFlight -= 1 }
            let body = status == 200 ? Self.jpeg : Data("{\"code\":\"x\"}".utf8)
            let type = status == 200 ? "image/jpeg" : "application/json"
            let h = "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nETag: \"\(v)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
