import Foundation
import Observation
import ShopCore

/// S23a 开通页（17a 给家人、17b 给收银员、25d 码过期）和「已登录的手机」的状态。
/// 网络只走 `DeviceBackend`（正常启动 = 真服务器；UI 测试 = 桩服务器），令牌每次现取。
@MainActor @Observable
final class PairingModel {
    enum Tab: Equatable { case family, cashier }

    /// 码这一块现在显示什么
    enum CodeState: Equatable {
        case idle                 // 收银员页还没出码
        case loading
        /// 正在显示：码、到期时刻（服务器时间）、给谁的（收银员称呼）
        case showing(PairingToken, expires: Date, label: String?)
        case expired              // 25d：这个码过期了 / 换一个新码
        case used(String?)        // 对方已经扫了（服务器定下的称呼）
        case failed(String)
    }

    let backend: DeviceBackend
    /// 服务器时间的「现在」（手机时间 + 上次同步量出的偏差）：倒计时按服务器的 expires_at 算，手机时钟不准也不提前或推后
    let serverNow: () -> Date
    /// 轮询间隔（测试可以调短）
    var pollInterval: Duration = .seconds(2)

    private(set) var tab: Tab = .family
    /// 上限按码点数算（服务器 ajv 的 maxLength 数的是码点，带 ZWJ 的表情一个字符占好几个码点）
    var cashierName = "" {
        didSet {
            if cashierName.unicodeScalars.count > Self.labelMax {
                cashierName = String(String.UnicodeScalarView(cashierName.unicodeScalars.prefix(Self.labelMax)))
            }
        }
    }
    private(set) var code: CodeState = .idle
    private(set) var devices: [DeviceInfo]?
    private(set) var devicesError: String?
    /// 「让它退出」确认面板对着的手机（26）
    var confirmRevoke: DeviceInfo? {
        // 换了一台（或关了面板）：上一台的出错提示不带过去
        didSet { if confirmRevoke?.id != oldValue?.id { revokeError = nil } }
    }
    private(set) var revoking = false
    private(set) var revokeError: String?
    /// 设置页「已登录的手机」右侧的台数、「待确认的账」笔数跟着刷新
    var onDevicesChanged: (([DeviceInfo]) -> Void)?

    private var poll: Task<Void, Never>?
    private var generation = 0

    /// 服务器的称呼上限（契约 pairing-tokens 的 label maxLength 40）
    static let labelMax = 40

    init(backend: DeviceBackend, serverNow: @escaping () -> Date) {
        self.backend = backend
        self.serverNow = serverNow
    }

    // MARK: 切页、出码

    /// 进页面：家人页直接出一个码，并拉一次手机列表。
    /// 从这页点进别的页（「待确认的账」）再回来也会走这里：离开时停了轮询，回来要接上——
    /// 正在显示的码接着轮询（已经到点的马上显示过期），离开时还在出码的那次结果被丢了，重新出一个
    func appear() {
        switch code {
        case .idle: if tab == .family { newCode() }
        case .loading: newCode()
        case .showing(let t, let expires, _):
            if poll == nil {
                generation += 1
                startPolling(t, expires: expires, gen: generation)
            }
        case .expired, .used, .failed: break
        }
        Task { await refreshDevices() }
    }

    /// 离开页面：停轮询（出的码过 2 分钟自己作废）
    func disappear() {
        poll?.cancel()
        poll = nil
        generation += 1
    }

    func select(_ t: Tab) {
        guard t != tab else { return }
        poll?.cancel()
        generation += 1
        tab = t
        code = .idle
        if t == .family { newCode() }
    }

    var trimmedName: String { cashierName.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 17b：没写称呼时「出码」是灰的
    var canIssueCashier: Bool { !trimmedName.isEmpty && code != .loading }

    /// 称呼和一台还在用的手机重名：不拦，告诉人新手机会叫什么（服务器按「名字 + 2、3…」加序号，`uniqueLabel`）
    var duplicateHint: String? {
        let name = trimmedName
        guard !name.isEmpty, let devices else { return nil }
        let taken = Set(devices.filter { !$0.revoked }.map(\.label))
        guard taken.contains(name) else { return nil }
        return "已经有一台叫「\(name)」的手机，新的会叫「\(Self.uniqueLabel(name, taken: taken))」"
    }

    /// 和服务器 `uniqueLabel` 同一个规则
    static func uniqueLabel(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while true {
            let suffix = String(n)
            let label = String(base.prefix(labelMax - suffix.count)) + suffix
            if !taken.contains(label) { return label }
            n += 1
        }
    }

    /// 出一个新码（家人页进来、「换一个新码」、收银员页「出码」、用过后「再出一个码」）
    func newCode() {
        let role: Role = tab == .family ? .family : .cashier
        let label: String? = tab == .cashier ? trimmedName : nil
        if role == .cashier, label?.isEmpty != false { return }
        poll?.cancel()
        generation += 1
        let gen = generation
        code = .loading
        Task {
            do {
                let t = try await backend.createPairingToken(role, label)
                guard gen == generation else { return }
                guard let expires = APIClient.date(t.expiresAt) else { code = .failed("服务器回的码看不懂，再试一次"); return }
                code = .showing(t, expires: expires, label: label)
                startPolling(t, expires: expires, gen: gen)
            } catch {
                guard gen == generation else { return }
                code = .failed(Self.message(error))
            }
        }
    }

    /// 还剩几秒（向上取整，到 0 为止）
    func remainingSeconds(at now: Date) -> Int {
        guard case .showing(_, let expires, _) = code else { return 0 }
        return max(0, Int(expires.timeIntervalSince(now).rounded(.up)))
    }

    /// 1:48
    static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private func startPolling(_ t: PairingToken, expires: Date, gen: Int) {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = expires.timeIntervalSince(self.serverNow())
                // 本机倒计时到 0 就显示过期（25d）；最后再问一次，免得最后一刻刚被扫了却显示过期
                if left <= 0 {
                    let last = try? await self.backend.pairingStatus(t.id)
                    guard gen == self.generation else { return }
                    if let last, last.status == .used { self.markUsed(last.usedByLabel) } else { self.code = .expired }
                    return
                }
                try? await Task.sleep(for: min(self.pollInterval, .milliseconds(Int(left * 1000) + 50)))
                guard !Task.isCancelled, gen == self.generation else { return }
                guard let s = try? await self.backend.pairingStatus(t.id), gen == self.generation else { continue }
                switch s.status {
                case .waiting: continue
                case .used: self.markUsed(s.usedByLabel); return
                case .expired: self.code = .expired; return
                }
            }
        }
    }

    private func markUsed(_ label: String?) {
        code = .used(label)
        Task { await refreshDevices() }
    }

    // MARK: 已登录的手机

    func refreshDevices() async {
        do {
            let list = try await backend.devices()
            devices = list
            devicesError = nil
            onDevicesChanged?(list)
        } catch {
            devicesError = Self.message(error)
        }
    }

    /// 26「让它退出」确认后
    func revokeConfirmed() async {
        guard let d = confirmRevoke, !revoking else { return }
        revoking = true
        defer { revoking = false }
        do {
            try await backend.revoke(d.id)
            revokeError = nil
            confirmRevoke = nil
            await refreshDevices()
        } catch {
            revokeError = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        switch error as? APIError {
        case .server(_, "delete_pending", _, _): "账号正在注销，不能开通新手机"
        case .server(_, "forbidden", _, _): "这台手机不能做这个"
        case .server(_, "cannot_revoke_self", _, _): "不能让这台手机自己退出，要退出请用「退出登录」"
        case .transport: "没连上服务器，联网后再试"
        default: "没办成，再试一次"
        }
    }
}

/// 开通页用到的网络调用。正常启动接 `APIClient`，令牌每次从钥匙串现取
struct DeviceBackend: Sendable {
    var createPairingToken: @Sendable (Role, String?) async throws -> PairingToken
    var pairingStatus: @Sendable (UUID) async throws -> PairingStatus
    var devices: @Sendable () async throws -> [DeviceInfo]
    var revoke: @Sendable (UUID) async throws -> Void
    var heldOps: @Sendable () async throws -> [HeldOp]
    var resolveHeld: @Sendable (UUID, Bool) async throws -> HeldResolution

    struct NoToken: Error {}

    static func live(api: APIClient, token: @escaping @Sendable () throws -> String) -> DeviceBackend {
        DeviceBackend(
            createPairingToken: { role, label in try await api.createPairingToken(role: role, label: label, token: try token()) },
            pairingStatus: { id in try await api.pairingStatus(id: id, token: try token()) },
            devices: { try await api.devices(token: try token()) },
            revoke: { id in try await api.revokeDevice(id: id, token: try token()) },
            heldOps: { try await api.heldOps(token: try token()) },
            resolveHeld: { id, accept in try await api.resolveHeld(id: id, accept: accept, token: try token()) }
        )
    }
}

extension DeviceInfo {
    /// 17a 每行下面的小字：「家人 · 刚刚」「收银员 · 今天 19:32」
    func subtitle(now: Date, calendar: Calendar = .shanghai) -> String {
        let role = role == .cashier ? "收银员" : "家人"
        guard let seen = (lastSeenAt ?? Optional(createdAt)).flatMap(APIClient.date) else { return role }
        return "\(role) · \(Self.when(seen, now: now, calendar: calendar))"
    }

    static func when(_ t: Date, now: Date, calendar: Calendar) -> String {
        if now.timeIntervalSince(t) < 5 * 60 { return "刚刚" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "zh_CN")
        if calendar.isDate(t, inSameDayAs: now) { f.dateFormat = "HH:mm"; return "今天 \(f.string(from: t))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(t, inSameDayAs: y) {
            f.dateFormat = "HH:mm"; return "昨天 \(f.string(from: t))"
        }
        f.dateFormat = "M月d日"
        return f.string(from: t)
    }

    /// 17a 的标题：收银员后面带「（收银）」，这台带「（这台）」
    var title: String {
        label + (isMe ? "（这台）" : role == .cashier ? "（收银）" : "")
    }
}

extension Calendar {
    /// 上海时区的公历（店在江阴，「今天 / 昨天」按店里的日子）
    static var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
}
