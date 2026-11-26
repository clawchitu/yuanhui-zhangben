import Foundation
import Observation
import os
import ShopCore

/// 登录页（13 / 25c）和扫码登录页（14 / 27b）的状态（S21）。成功后开好本地会话，交给 `onSignedIn` 切到首页（新会话
/// 没做完首次进入，所以先到 16 / 16b）。本段不做同步，登录后进的是空首页。
@MainActor @Observable
final class LoginModel {
    var username: String
    var password = ""
    var showPassword = false
    private(set) var busy = false
    /// 账号密码登录失败的一句话（红字）
    private(set) var message: String?
    /// 25c：锁到几点；过了这个时间自动解除
    private(set) var lockedUntil: Date?
    /// 扫码登录页的一句话（过期码、用过的码、不是登录码……）
    private(set) var scanMessage: String?
    var scanOpen = false
    /// 登录页顶上的一句说明（S23b：刚申请了注销，「X 之前用账号密码登录，可以撤回」）
    var notice: String?

    let services: AppServices?
    let db: LocalDB
    private let onSignedIn: @MainActor (LocalSession) -> Void
    /// 现在几点（测试、截图夹具可换成稿子上的时间）
    var now: () -> Date
    private var unlockTask: Task<Void, Never>?

    init(services: AppServices?, db: LocalDB, now: @escaping () -> Date = Date.init,
         onSignedIn: @escaping @MainActor (LocalSession) -> Void) {
        self.services = services
        self.db = db
        self.now = now
        self.onSignedIn = onSignedIn
        username = services?.defaults.string(forKey: AuthDefaults.lastUsername) ?? ""
    }

    /// 账号框右边小字「记住了」：框里就是上次登录成功的那个用户名
    var remembered: Bool {
        guard let last = services?.defaults.string(forKey: AuthDefaults.lastUsername), !last.isEmpty else { return false }
        return last == username
    }

    var locked: Bool { lockedUntil.map { $0 > now() } ?? false }

    var canSubmit: Bool {
        !busy && !locked && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    /// 「20:03」（上海时间）
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 25c 黄条
    var lockText: String? {
        guard locked, let lockedUntil else { return nil }
        return "密码错了 5 次，锁 15 分钟。\(Self.clock(lockedUntil)) 以后再试，或者让家人出码"
    }

    func setLocked(until d: Date) {
        lockedUntil = d
        message = nil
        unlockTask?.cancel()
        let wait = d.timeIntervalSince(now())
        guard wait > 0 else { return }
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 0.5))
            guard !Task.isCancelled else { return }
            self?.lockedUntil = nil
        }
    }

    private static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "login")

    // MARK: 账号密码

    func login() async {
        guard canSubmit else { return }
        guard let services else { message = "连不上服务器，看看网络再试"; return }
        let user = username.trimmingCharacters(in: .whitespaces)
        busy = true
        message = nil
        defer { busy = false }
        let deviceId = UUID()
        let pending = services.pendingDeviceLabel
        do {
            let grant = try await services.api.login(username: user, password: password, deviceId: deviceId,
                                                     label: pending.flatMap(Self.validLabel))
            services.defaults.set(user, forKey: AuthDefaults.lastUsername)
            // 带着去的名字已经报上去了（重名时服务器会加序号，以响应为准）
            if pending != nil { services.pendingDeviceLabel = nil }
            let session = try await services.establish(grant, deviceId: deviceId, db: db)
            services.rememberUsername(user, deviceId: deviceId)
            finish(session)
        } catch let e as APIError {
            Self.logger.notice("登录没成功：\(String(describing: e), privacy: .public)")
            handle(e)
        } catch {
            Self.logger.error("登录后开本地会话没成功：\(String(describing: error), privacy: .public)")
            message = "登录没成功，再试一次"
        }
    }

    private func handle(_ e: APIError) {
        switch e {
        case .server(423, _, let until, _):
            setLocked(until: until ?? now().addingTimeInterval(15 * 60))
        case .server(_, "bad_credentials", _, _):
            message = "账号或密码不对"
            password = ""
        case .server(_, "rate_limited", _, _), .server(429, _, _, _):
            message = "试得太多了，过一会儿再试"
        case .transport:
            message = "连不上服务器，看看网络再试"
        case .redirected:
            message = Self.redirectedText
        default:
            message = "登录没成功，再试一次"
        }
    }

    // MARK: 看看演示

    func demo() async {
        guard let services, !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        let deviceId = UUID()
        do {
            let grant = try await services.api.demoLogin(deviceId: deviceId)
            finish(try await services.establish(grant, deviceId: deviceId, db: db))
        } catch let e as APIError {
            switch e {
            case .transport: message = "连不上服务器，看看网络再试"
            case .redirected: message = Self.redirectedText
            default: message = "演示小店现在进不去，过一会儿再试"
            }
        } catch {
            message = "演示小店现在进不去，过一会儿再试"
        }
    }

    // MARK: 扫码登录

    private var lastScan: (code: String, at: Date)?

    /// 相机认出一个码（原样，不经 `ScanHub`：登录码里有 `:`）。同一个码 2 秒内重复交来（相机每帧都认）不再处理
    func scanned(_ raw: String) async {
        guard !busy else { return }
        if let last = lastScan, last.code == raw, now().timeIntervalSince(last.at) < 2 { return }
        lastScan = (raw, now())
        guard let code = PairingCode.parse(raw) else {
            scanMessage = "这不是元辉账本的登录码，让家里人打开「给家里人 / 收银员开通」那页"
            return
        }
        guard let services else { scanMessage = "连不上服务器，看看网络再试"; return }
        busy = true
        scanMessage = nil
        defer { busy = false }
        let deviceId = UUID()
        do {
            let grant = try await services.api.redeem(code: code, deviceId: deviceId)
            let session = try await services.establish(grant, deviceId: deviceId, db: db)
            scanOpen = false
            finish(session)
        } catch let e as APIError {
            scanMessage = switch e {
            case .server(_, "pairing_expired", _, _): "这个码过期了，让家里人换一个新码"
            case .server(_, "pairing_used", _, _): "这个码已经用过了，让家里人换一个新码"
            case .server(_, "not_found", _, _): "这个码不对，让家里人换一个新码"
            case .server(_, "delete_pending", _, _): "这家店的账号正在注销，现在不能开通新手机"
            case .server(_, "rate_limited", _, _): "试得太多了，过一会儿再试"
            // 兑码只发一次（不退回默认地址重发）：没连上就让用户重扫
            case .transport: "没连上服务器，看看网络，再扫一次"
            case .redirected: Self.redirectedText
            default: "没登录上，再扫一次"
            }
        } catch {
            scanMessage = "没登录上，再扫一次"
        }
    }

    /// 服务器想把请求转去别的地址：没跟过去，账号密码没有发出去
    static let redirectedText = "服务器地址不对，已经拦下，登录信息没有发出去。过一会儿再试，还不行就找店里"

    private func finish(_ session: LocalSession) {
        password = ""
        notice = nil
        onSignedIn(session)
    }

    /// 契约 `DeviceLabel`：1–40 个码点（ajv 的 maxLength 按码点数），本地改名用的是同一个口径
    static func validLabel(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.count <= LocalDB.deviceLabelMaxLength else { return nil }
        return t
    }
}
