import Network
import XCTest

/// S23a 开通与设备管理（plan-v2 §8 S23a 验收，夹具 + 本机桩服务器）。
/// 两台手机真连服务器的那几条（A 出码 B 扫码 20 秒内看到流水、同一个码第二台扫失败、扫收银员码进 02）在 `S23aLiveUITests`。
@MainActor
final class S23aUITests: XCTestCase {
    private var stub: DeviceStub!
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try DeviceStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func idle(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func launch(route: String = "pairing", role: String = "family", fixture: String = "home", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiFixture", fixture, "-uiRole", role, "-uiLargeText", "on", "-uiAPI", "http://localhost:\(stub.port)"]
        if !route.isEmpty { args += ["-uiRoute", route] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 元素整个在屏幕里、能点（大字时关键按钮不被挤出去）
    private func assertOnScreen(_ app: XCUIApplication, _ e: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(what) 存在", file: file, line: line)
        XCTAssertTrue(e.isHittable, "\(what) 能点", file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(what) 整个在屏幕里：\(e.frame)", file: file, line: line)
    }

    // MARK: 验收

    /// 17a：家人页一进来就出码（POST role=family、不带称呼），二维码里是 YHZB1:<码>，倒计时「1:5x 后失效，用过一次也失效」；
    /// 下面「已登录的手机」来自服务器：这台带「（这台）」、没有「让它退出」，别的手机有
    func testFamilyCodeAndDeviceList() throws {
        let app = launch()
        let qr = el(app, "pairing.qr")
        XCTAssertTrue(qr.waitForExistence(timeout: 15), "出了二维码")
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/pairing-tokens").count, 1)
        let body = try XCTUnwrap(stub.requests(method: "POST", path: "/v1/pairing-tokens").first?.json)
        XCTAssertEqual(body as? [String: String], ["role": "family"])
        XCTAssertEqual(qr.value as? String, "YHZB1:\(stub.lastCode)")
        let cd = el(app, "pairing.countdown")
        XCTAssertTrue(cd.label.contains("后失效，用过一次也失效"), cd.label)
        XCTAssertTrue(cd.label.hasPrefix("1:5") || cd.label.hasPrefix("2:00"), "倒计时从 2:00 开始：\(cd.label)")
        XCTAssertTrue(el(app, "devices.row.柜台手机").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "devices.row.柜台手机").label.contains("柜台手机（这台）"))
        XCTAssertFalse(el(app, "devices.revoke.柜台手机").exists, "不能让自己退出")
        XCTAssertTrue(el(app, "devices.revoke.爸爸的手机").exists)
        XCTAssertTrue(el(app, "devices.row.小王").label.contains("小王（收银）"))
        XCTAssertFalse(el(app, "devices.row.旧手机").exists, "已退出的手机不在「已登录的手机」里")
        XCTAssertEqual(stub.requests(method: "GET", path: "/v1/devices").first?.auth, "Bearer fixture-token")
        shot(app, "17a")
    }

    /// 25d：倒计时到 0 显示「这个码过期了」「换一个新码」；点了再出一个码，倒计时重新开始
    func testCountdownToZeroShowsExpiredAndRenews() {
        stub.ttl = 4
        let app = launch()
        XCTAssertTrue(el(app, "pairing.qr").waitForExistence(timeout: 15))
        let expired = el(app, "pairing.expired")
        XCTAssertTrue(expired.waitForExistence(timeout: 12), "到 0 显示过期")
        XCTAssertEqual(expired.label, "这个码过期了")
        XCTAssertFalse(el(app, "pairing.qr").exists, "过期的码不再当可扫的二维码显示")
        shot(app, "25d")
        stub.ttl = 120
        el(app, "pairing.renew").tap()
        XCTAssertTrue(el(app, "pairing.qr").waitForExistence(timeout: 10))
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/pairing-tokens").count, 2)
        XCTAssertEqual(el(app, "pairing.qr").value as? String, "YHZB1:\(stub.lastCode)")
        XCTAssertTrue(el(app, "pairing.countdown").label.hasPrefix("1:5") || el(app, "pairing.countdown").label.hasPrefix("2:00"))
    }

    /// 服务器先说过期了（出码的手机被退出、或服务器的钟快）：照样显示 25d
    func testServerSaysExpired() {
        stub.statusAfterPolls = (1, "expired", nil)
        let app = launch()
        XCTAssertTrue(el(app, "pairing.expired").waitForExistence(timeout: 15))
    }

    /// 对方扫了：显示「『妈妈的手机』已经登录了」，列表里多出这台，不自动再出码
    func testUsedShowsWhoAndRefreshesList() {
        stub.statusAfterPolls = (2, "used", "妈妈的手机")
        let app = launch()
        let used = el(app, "pairing.used")
        XCTAssertTrue(used.waitForExistence(timeout: 20))
        XCTAssertEqual(used.label, "「妈妈的手机」已经登录了")
        XCTAssertTrue(el(app, "devices.row.妈妈的手机").waitForExistence(timeout: 10), "列表刷新出新手机")
        idle(3)
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/pairing-tokens").count, 1, "不自动再出码")
        let polls = stub.requests(method: "GET").filter { $0.path.hasPrefix("/v1/pairing-tokens/") }.count
        idle(3)
        XCTAssertEqual(stub.requests(method: "GET").filter { $0.path.hasPrefix("/v1/pairing-tokens/") }.count, polls, "用过了就不再轮询")
    }

    /// 17b：收银员页没写称呼时「出码」是灰的；写了和已有手机重名的称呼，提示新手机会叫什么（不拦）；出码带称呼，
    /// 码下面写「给 小王 的码」
    func testCashierNameRequiredAndDuplicateHint() throws {
        let app = launch()
        XCTAssertTrue(el(app, "pairing.qr").waitForExistence(timeout: 15))
        el(app, "pairing.tab.cashier").tap()
        let issue = app.buttons["pairing.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertFalse(issue.isEnabled, "没写称呼时出码是灰的")
        XCTAssertFalse(el(app, "pairing.qr").exists, "收银员页先不出码")
        let name = app.textFields["pairing.name"]
        name.tap()
        name.typeText("   ")
        XCTAssertFalse(issue.isEnabled, "只有空格也算没写")
        name.typeText("小王")
        let dup = el(app, "pairing.duplicate")
        XCTAssertTrue(dup.waitForExistence(timeout: 5))
        XCTAssertEqual(dup.label, "已经有一台叫「小王」的手机，新的会叫「小王2」")
        XCTAssertTrue(issue.isEnabled)
        shot(app, "17b-dup")
        issue.tap()
        XCTAssertTrue(el(app, "pairing.qr").waitForExistence(timeout: 10))
        let posts = stub.requests(method: "POST", path: "/v1/pairing-tokens")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.last?.json as? [String: String], ["role": "cashier", "label": "小王"])
        XCTAssertTrue(el(app, "pairing.countdown").label.hasPrefix("给 小王 的码"), el(app, "pairing.countdown").label)
        shot(app, "17b")
    }

    /// 26：「让它退出」先弹确认面板；点「不了」什么都不发；确认了才发 revoke，列表里这台消失，设置页的台数跟着变
    func testRevokeAsksFirst() {
        let app = launch()
        let btn = el(app, "devices.revoke.爸爸的手机")
        XCTAssertTrue(btn.waitForExistence(timeout: 15))
        btn.tap()
        let title = el(app, "confirm.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "让「爸爸的手机」退出？")
        XCTAssertTrue(app.staticTexts["退出后它要重新扫码才能用。还没传上去的账会先传完。"].exists)
        // 抽屉里的字跟着大字模式：标题行高大字时约 32pt，抽屉没带上字号时约 25pt（只按系统默认字号）
        XCTAssertGreaterThan(title.frame.height, 29, "确认面板标题按大字模式显示：\(title.frame.height)")
        shot(app, "26")
        el(app, "devices.revoke.cancel").tap()
        wait("面板关上") { !self.el(app, "confirm.title").exists }
        XCTAssertEqual(stub.revokes, [], "点「不了」不发")
        btn.tap()
        XCTAssertTrue(el(app, "devices.revoke.confirm").waitForExistence(timeout: 5))
        el(app, "devices.revoke.confirm").tap()
        wait("面板关上、这台从列表消失") { !self.el(app, "confirm.title").exists && !self.el(app, "devices.row.爸爸的手机").exists }
        XCTAssertEqual(stub.revokes, [DeviceStub.dadId.lowercased()])
    }

    /// 设置页「已登录的手机」右侧的数来自服务器（S15-1）：服务器 2 台没退出 + 1 台退出了还有待确认的账 →「2 台」（不是稿子上的 3 台）
    func testSettingsDeviceCountFromServer() {
        stub.devices.removeAll { $0.label == "小王" }
        let app = launch(route: "settings")
        let item = el(app, "settings.item.devices")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        wait("台数来自服务器（现在「\(item.label)」）") { item.label.contains("2 台") }
        XCTAssertGreaterThanOrEqual(stub.requests(method: "GET", path: "/v1/devices").count, 1)
    }

    /// 「已登录的手机」页：同一个列表，同样先确认再退出
    func testDevicesPage() {
        let app = launch(route: "devices")
        XCTAssertTrue(el(app, "page.devices").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "devices.revoke.小王").waitForExistence(timeout: 10))
        el(app, "devices.revoke.小王").tap()
        XCTAssertEqual(el(app, "confirm.title").label, "让「小王」退出？")
        el(app, "devices.revoke.confirm").tap()
        wait("退出了") { self.stub.revokes == [DeviceStub.cashierId.lowercased()] }
    }

    /// 出码失败（账号正在注销）：说清楚原因，有「再试一次」
    func testCreateFailsDeletePending() {
        stub.createStatus = 403
        let app = launch()
        let err = el(app, "pairing.error")
        XCTAssertTrue(err.waitForExistence(timeout: 15))
        XCTAssertEqual(err.label, "账号正在注销，不能开通新手机")
        XCTAssertTrue(el(app, "pairing.renew").exists)
    }

    /// 收银员没有开通和设备管理：硬塞路由进来也只有「用不了」，一个请求都不发
    func testCashierCannotPairOrManage() {
        let app = launch(route: "pairing", role: "cashier")
        XCTAssertTrue(el(app, "page.denied").waitForExistence(timeout: 10))
        idle(2)
        XCTAssertTrue(stub.requests(method: "POST", path: "/v1/pairing-tokens").isEmpty)
        app.terminate()
        let app2 = launch(route: "devices", role: "cashier")
        XCTAssertTrue(el(app2, "page.denied").waitForExistence(timeout: 10))
        idle(1)
        XCTAssertTrue(stub.requests(method: "GET", path: "/v1/devices").isEmpty)
    }

    // MARK: 最大辅助字号：关键按钮都在屏幕里、能点

    func testMaxTextFamily() {
        let app = launch(extra: Self.maxAX)
        XCTAssertTrue(el(app, "pairing.qr").waitForExistence(timeout: 15))
        assertOnScreen(app, el(app, "pairing.tab.cashier"), "切到收银员")
        shot(app, "17a-ax")
        let revoke = el(app, "devices.revoke.爸爸的手机")
        XCTAssertTrue(revoke.waitForExistence(timeout: 10))
        for _ in 0..<6 where !revoke.isHittable { app.swipeUp() }
        assertOnScreen(app, revoke, "让它退出")
        revoke.tap()
        let confirm = el(app, "devices.revoke.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for _ in 0..<4 where !el(app, "devices.revoke.cancel").isHittable { el(app, "confirm.sheet").swipeUp() }
        assertOnScreen(app, el(app, "devices.revoke.cancel"), "不了")
        shot(app, "26-ax")
    }

    func testMaxTextCashierAndExpired() {
        stub.ttl = 3
        let app = launch(extra: Self.maxAX)
        let renew = el(app, "pairing.renew")
        XCTAssertTrue(renew.waitForExistence(timeout: 15))
        assertOnScreen(app, renew, "换一个新码")
        shot(app, "25d-ax")
        el(app, "pairing.tab.cashier").tap()
        let name = app.textFields["pairing.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("小李\n")
        assertOnScreen(app, app.buttons["pairing.issue"], "出码")
        XCTAssertTrue(app.buttons["pairing.issue"].isEnabled)
        shot(app, "17b-ax")
    }
}

/// 开通和设备接口的桩（契约 openapi.yaml「设备与开通」）
final class DeviceStub: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: Data
        let auth: String
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    }
    struct Device {
        var id: String
        var label: String
        var role: String
        var isMe = false
        var revoked = false
        var held = 0
    }

    static let meId = "5EED0000-0000-4000-8000-00000000F001"
    static let dadId = "11111111-2222-4333-8444-555555555555"
    static let cashierId = "66666666-7777-4888-8999-aaaaaaaaaaaa"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "s23a-device-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private var tokens: [String: (code: String, expires: Date, polls: Int)] = [:]
    private var ttlValue: TimeInterval = 120
    private var afterPolls: (Int, String, String?)?
    private var createStatusValue = 201
    private var devicesValue: [Device] = [
        Device(id: meId.lowercased(), label: "柜台手机", role: "family", isMe: true),
        Device(id: dadId, label: "爸爸的手机", role: "family"),
        Device(id: cashierId, label: "小王", role: "cashier"),
        Device(id: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff", label: "旧手机", role: "cashier", revoked: true, held: 2),
    ]
    private var revokeLog: [String] = []
    private var heldValue: [String] = []
    private var staleValue: Set<String> = []
    private var resolveLog: [(String, String)] = []
    private var last = ""

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() throws -> DeviceStub {
        let s = try DeviceStub()
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "DeviceStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
    /// 新出的码几秒后过期
    var ttl: TimeInterval { get { lock.withLock { ttlValue } } set { lock.withLock { ttlValue = newValue } } }
    /// 第 n 次轮询起回这个状态（used 带称呼，并把这台加进手机列表）
    var statusAfterPolls: (Int, String, String?)? { get { lock.withLock { afterPolls } } set { lock.withLock { afterPolls = newValue } } }
    var createStatus: Int { get { lock.withLock { createStatusValue } } set { lock.withLock { createStatusValue = newValue } } }
    var devices: [Device] { get { lock.withLock { devicesValue } } set { lock.withLock { devicesValue = newValue } } }
    var revokes: [String] { lock.withLock { revokeLog } }
    /// 待确认的账（每笔一段 HeldOp JSON，id 在 `heldIds` 里）
    var held: [String] { get { lock.withLock { heldValue } } set { lock.withLock { heldValue = newValue } } }
    /// 这些 id 「记上」回 409 stale
    var staleIds: Set<String> { get { lock.withLock { staleValue } } set { lock.withLock { staleValue = newValue } } }
    /// 收到的 resolve：(id, action)
    var resolves: [(String, String)] { lock.withLock { resolveLog } }

    /// 一笔被退出的手机补传的进货（演示数据里的青岛啤酒，3 罐 × ¥12.00）
    static func heldStockIn(id: String, label: String = "旧手机", role: String = "family", canAccept: Bool = true, type: String = "stock_in") -> String {
        #"{"id":"\#(id)","device_id":"bbbbbbbb-cccc-4ddd-8eee-ffffffffffff","device_label":"\#(label)","device_role":"\#(role)","type":"\#(type)","occurred_at":"2026-11-25T11:32:00.000Z","payload":{"entry_id":"aaaaaaaa-0000-4000-8000-000000000001","product_id":"5eed0000-0000-4000-8000-000000000202","barcode":"6901035600016","pack_qty":1,"pack_count":3,"unit_cost_fen":1200,"counted_qty":40,"base_ver":1},"can_accept":\#(canAccept)}"#
    }
    var lastCode: String { lock.withLock { last } }
    func requests(method: String, path: String? = nil) -> [Request] {
        lock.withLock { log.filter { $0.method == method && (path == nil || $0.path == path) } }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                func header(_ n: String) -> String {
                    lines.dropFirst().first { $0.lowercased().hasPrefix(n + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                let length = Int(header("content-length")) ?? 0
                let body = b[end.upperBound...]
                if body.count >= length {
                    self.respond(c, lines, auth: header("authorization"), body: Data(body.prefix(length)))
                    return
                }
            }
            if done || err != nil { c.cancel() } else { self.receive(c, b) }
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func respond(_ c: NWConnection, _ lines: [String], auth: String, body: Data) {
        let first = lines.first?.split(separator: " ") ?? []
        let method = first.first.map(String.init) ?? ""
        let path = String((first.dropFirst().first.map(String.init) ?? "").split(separator: "?").first ?? "")
        let (status, out): (Int, String) = lock.withLock {
            log.append(Request(method: method, path: path, body: body, auth: auth))
            let parts = path.split(separator: "/").map(String.init)
            switch (method, parts.count) {
            case ("POST", 2) where parts[1] == "pairing-tokens":
                guard createStatusValue == 201 else { return (createStatusValue, #"{"code":"delete_pending"}"#) }
                let id = UUID().uuidString.lowercased(), code = "code\(log.count)"
                let exp = Date().addingTimeInterval(ttlValue)
                tokens[id] = (code, exp, 0)
                last = code
                return (201, #"{"id":"\#(id)","code":"\#(code)","expires_at":"\#(Self.iso(exp))"}"#)
            case ("GET", 3) where parts[1] == "pairing-tokens":
                guard var t = tokens[parts[2]] else { return (404, #"{"code":"not_found"}"#) }
                t.polls += 1
                tokens[parts[2]] = t
                if let (n, st, label) = afterPolls, t.polls >= n {
                    if st == "used", let label {
                        if !devicesValue.contains(where: { $0.label == label }) {
                            devicesValue.append(Device(id: UUID().uuidString.lowercased(), label: label, role: "family"))
                        }
                        return (200, #"{"status":"used","used_by_label":"\#(label)"}"#)
                    }
                    return (200, #"{"status":"\#(st)"}"#)
                }
                return (200, #"{"status":"\#(t.expires <= Date() ? "expired" : "waiting")"}"#)
            case ("GET", 2) where parts[1] == "devices":
                let now = Self.iso(Date())
                let rows = devicesValue.map {
                    #"{"id":"\#($0.id.lowercased())","label":"\#($0.label)","role":"\#($0.role)","created_at":"\#(now)","last_seen_at":"\#(now)","is_me":\#($0.isMe),"revoked":\#($0.revoked),"held_count":\#($0.held)}"#
                }
                return (200, #"{"devices":[\#(rows.joined(separator: ","))]}"#)
            case ("GET", 2) where parts[1] == "held-ops":
                return (200, #"{"held":[\#(heldValue.joined(separator: ","))]}"#)
            case ("POST", 4) where parts[1] == "held-ops" && parts[3] == "resolve":
                let action = ((try? JSONSerialization.jsonObject(with: body)) as? [String: String])?["action"] ?? ""
                resolveLog.append((parts[2], action))
                guard let i = heldValue.firstIndex(where: { $0.contains(#""id":"\#(parts[2])""#) }) else { return (404, #"{"code":"not_found"}"#) }
                if action == "accept", staleValue.contains(parts[2]) { return (409, #"{"code":"stale"}"#) }
                heldValue.remove(at: i)
                return (200, action == "accept" ? #"{"id":"\#(parts[2])","status":"applied"}"# : #"{"id":"\#(parts[2])","status":"rejected","code":"discarded"}"#)
            case ("POST", 4) where parts[1] == "devices" && parts[3] == "revoke":
                revokeLog.append(parts[2])
                if let i = devicesValue.firstIndex(where: { $0.id.lowercased() == parts[2] }) { devicesValue.remove(at: i) }
                return (204, "")
            default:
                return (404, #"{"code":"not_found"}"#)
            }
        }
        let h = status == 204
            ? "HTTP/1.1 204 X\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(out.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + Data(out.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
