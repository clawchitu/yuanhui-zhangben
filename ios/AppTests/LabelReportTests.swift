import Foundation
import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// PR #35 评审修 5：改名补报（`PATCH /v1/devices/me`）同一时间只允许一趟在路上。
/// 回前台和登录后同时触发、或者连着触发几次，都只上报一次；在路上时又改了名，旧响应不覆盖新名字。
/// 用 `URLProtocol` 桩接住请求（不连网），回包故意慢 0.3 秒，让几次触发确实重叠。
@MainActor
final class LabelReportTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("label-\(UUID().uuidString)")

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RenameStub.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel(pending: String?) throws -> (AppModel, AppServices) {
        let db = try LocalDB(path: dir.appendingPathComponent("live.sqlite").path)
        let id = UUID()
        let s = try LocalSession(deviceId: id, storeId: UUID(), role: .family, tokenRef: TokenRef.forDevice(id),
                                 storeName: "店", deviceLabel: "手机")
        try db.beginSession(s)
        let tokens = MemoryTokenStore()
        try tokens.save("t", ref: s.tokenRef)
        let defaults = UserDefaults(suiteName: "label-\(UUID().uuidString)")!
        let policy = APIBasePolicy(hosts: ["api.yuanhuishop.cn"])
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn", policy: policy, defaults: defaults))
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [RenameStub.self]
        let services = AppServices(api: APIClient(bases: bases, session: APIClient.makeSession(conf)), tokens: tokens,
                                   defaults: defaults, build: 1)
        services.pendingDeviceLabel = pending
        let model = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        model.services = services
        return (model, services)
    }

    /// 回前台 + 登录后同时触发（再加一次重复）：服务器只收到一次补报
    func testConcurrentTriggersReportOnce() async throws {
        let (model, services) = try makeModel(pending: "爸爸的手机")
        async let a: Void = model.reportPendingLabel()   // 回前台
        async let b: Void = model.reportPendingLabel()   // 登录后
        async let c: Void = model.reportPendingLabel()
        _ = await (a, b, c)
        XCTAssertEqual(RenameStub.labels, ["爸爸的手机"], "并发触发只能上报一次")
        XCTAssertEqual(model.labelReportsSent, 1)
        XCTAssertNil(services.pendingDeviceLabel, "报上了就清掉")
        XCTAssertEqual(model.session.deviceLabel, "爸爸的手机")
    }

    /// 一趟结束后再触发（下一次回前台、又改了名）照常能报：保护只管「同一时间」
    func testLaterTriggerReportsAgain() async throws {
        let (model, services) = try makeModel(pending: "爸爸的手机")
        await model.reportPendingLabel()
        services.pendingDeviceLabel = "妈妈的手机"
        await model.reportPendingLabel()
        XCTAssertEqual(RenameStub.labels, ["爸爸的手机", "妈妈的手机"])
        XCTAssertNil(services.pendingDeviceLabel)
    }

    /// 在路上时又改了名：旧那趟回来不写回、不清 pending，同一趟接着报新名字；最后本机和服务器都是新名字
    func testRenameWhileInFlightSendsNewNameAndIgnoresStaleReply() async throws {
        let (model, services) = try makeModel(pending: "旧名字")
        let first = Task { await model.reportPendingLabel() }
        while RenameStub.labels.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try model.rename("新名字")              // 改名本身也会触发一次补报：在途，不另发
        await first.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(RenameStub.labels, ["旧名字", "新名字"], "不重复发，新名字接着报")
        XCTAssertNil(services.pendingDeviceLabel)
        XCTAssertEqual(model.session.deviceLabel, "新名字", "旧响应没有覆盖新名字")
    }

    /// 报失败留着 pending，在途标记也清掉：下一次触发会重新发
    func testFailureKeepsPendingAndAllowsRetry() async throws {
        let (model, services) = try makeModel(pending: "爸爸的手机")
        RenameStub.status = 503
        async let a: Void = model.reportPendingLabel()
        async let b: Void = model.reportPendingLabel()
        _ = await (a, b)
        XCTAssertEqual(RenameStub.labels.count, 1)
        XCTAssertEqual(services.pendingDeviceLabel, "爸爸的手机")
        RenameStub.status = 200
        await model.reportPendingLabel()
        XCTAssertEqual(RenameStub.labels.count, 2)
        XCTAssertNil(services.pendingDeviceLabel)
    }
}

/// 接住 `PATCH /v1/devices/me`：记下名字，0.3 秒后按 `status` 回（200 时原样回名字）
final class RenameStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _labels: [String] = []
    nonisolated(unsafe) private static var _status = 200
    static var labels: [String] { lock.withLock { _labels } }
    static var status: Int {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    static func reset() { lock.withLock { _labels = []; _status = 200 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let label = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["label"] as? String ?? "?"
        let ok = request.httpMethod == "PATCH" && request.url?.path == "/v1/devices/me"
        Self.lock.withLock { Self._labels.append(ok ? label : "unexpected \(request.url?.path ?? "")") }
        let status = Self.status
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            let reply = status == 200 ? (try? JSONSerialization.data(withJSONObject: ["label": label])) ?? Data()
                                      : Data(#"{"code":"unavailable"}"#.utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }
}
