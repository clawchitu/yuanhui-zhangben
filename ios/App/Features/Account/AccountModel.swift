import Foundation
import Observation
import ShopCore

/// S23b「账号与密码」（21a 下级页）用到的网络调用。正常启动接 `APIClient`，令牌每次从钥匙串现取；
/// UI 测试接桩服务器（`-uiAPI`）
struct AccountBackend: Sendable {
    var changePassword: @Sendable (_ old: String, _ new: String) async throws -> Void
    var revokeOthers: @Sendable () async throws -> Int
    var me: @Sendable () async throws -> AccountMe

    static func live(api: APIClient, token: @escaping @Sendable () throws -> String) -> AccountBackend {
        AccountBackend(
            changePassword: { old, new in try await api.changePassword(old: old, new: new, token: try token()) },
            revokeOthers: { try await api.revokeOtherDevices(token: try token()) },
            me: { try await api.me(token: try token()) }
        )
    }
}

/// 「账号与密码」页的状态：账号名、改密码、让其他手机全部退出
@MainActor @Observable
final class AccountModel {
    let backend: AccountBackend

    var oldPassword = "" { didSet { clampField(\.oldPassword) } }
    var newPassword = "" { didSet { clampField(\.newPassword) } }
    var newAgain = "" { didSet { clampField(\.newAgain) } }
    private(set) var changing = false
    /// 改密码那一块的一句话：出错（红字）或改好了
    private(set) var passwordMessage: String?
    private(set) var passwordChanged = false

    /// 「让其他手机全部退出」的 26 确认面板
    struct AskRevoke: Identifiable { let id = 0 }
    var askRevokeOthers: AskRevoke? { didSet { if askRevokeOthers == nil { revokeError = nil } } }
    private(set) var revokingOthers = false
    private(set) var revokeError: String?
    private(set) var revokeDone: String?

    /// `/v1/me` 给了账号名（扫码开通的家用手机、升级前登录的手机本机没记着）：本机记下、页面显示
    var onUsername: ((String) -> Void)?

    init(backend: AccountBackend) {
        self.backend = backend
    }

    private func clampField(_ k: ReferenceWritableKeyPath<AccountModel, String>) {
        let v = self[keyPath: k]
        let c = PasswordRule.clamp(v)
        if c != v { self[keyPath: k] = c }
    }

    // MARK: 改密码

    var canChange: Bool { !changing && !oldPassword.isEmpty && !newPassword.isEmpty && !newAgain.isEmpty }

    /// 手机上先按服务器的规则拦一道（长度 8–256、两次一样），过了才发
    func changePassword() async {
        guard canChange else { return }
        passwordChanged = false
        if let p = PasswordRule.check(old: oldPassword, new: newPassword, again: newAgain) {
            passwordMessage = Self.text(p)
            return
        }
        changing = true
        defer { changing = false }
        do {
            try await backend.changePassword(oldPassword, newPassword)
            oldPassword = ""; newPassword = ""; newAgain = ""
            passwordChanged = true
            passwordMessage = "密码改好了。别的手机不用重新登录，下次登录用新密码"
        } catch {
            let f = AccountFailure(error)
            if f == .wrongPassword { oldPassword = "" }
            passwordMessage = Self.text(f, action: "改密码")
        }
    }

    static func text(_ p: PasswordRule.Problem) -> String {
        switch p {
        case .oldEmpty: "先输原来的密码"
        case .tooShort: "新密码太短了，至少 \(PasswordRule.minLength) 位"
        case .tooLong: "密码太长了，最多 \(PasswordRule.maxLength) 位"
        case .mismatch: "两次输的新密码不一样，再输一次"
        }
    }

    /// 服务器回的码 → 一句话（原密码输错的限速和申请注销共用一个计数，§14 S03-8）
    static func text(_ f: AccountFailure, action: String) -> String {
        switch f {
        case .wrongPassword: return "密码不对，再输一次"
        case .rateLimited:
            return "密码错了太多次，\(f.waitMinutes ?? 15) 分钟以后再试"
        case .invalid: return "新密码要 \(PasswordRule.minLength) 到 \(PasswordRule.maxLength) 位"
        case .forbidden: return "这台手机不能\(action)"
        case .signedOut: return "这台手机已经退出登录了，重新登录后再\(action)"
        case .network: return "没连上服务器，联网后再试"
        case .other: return "没办成，再试一次"
        }
    }

    // MARK: 让其他手机全部退出

    func revokeOthersConfirmed() async {
        guard !revokingOthers else { return }
        revokingOthers = true
        defer { revokingOthers = false }
        do {
            let n = try await backend.revokeOthers()
            revokeError = nil
            askRevokeOthers = nil
            revokeDone = n > 0 ? "已经让 \(n) 台手机退出了" : "没有别的手机在登录"
        } catch {
            revokeError = Self.text(AccountFailure(error), action: "让别的手机退出")
        }
    }

    // MARK: 账号名

    /// 进页面问一次服务器：本机没记着账号名的（升级前登录的手机）用 `/v1/me` 给的。拿不到就算了
    func refresh() async {
        guard let me = try? await backend.me() else { return }
        if let name = me.username { onUsername?(name) }
    }
}

extension AppModel {
    /// 「账号与密码」页的状态。没有网络服务（夹具没给桩）时为 nil，页面只出一句「要联网」
    func makeAccountModel() -> AccountModel? {
        guard let services else { return nil }
        let tokens = services.tokens, ref = session.tokenRef
        let backend = AccountBackend.live(api: services.api) {
            guard let t = try tokens.token(ref: ref) else { throw DeviceBackend.NoToken() }
            return t
        }
        let m = AccountModel(backend: backend)
        let deviceId = session.deviceId
        m.onUsername = { [weak self] name in
            guard let self, self.accountName != name else { return }
            self.accountName = name
            services.rememberUsername(name, deviceId: deviceId)
        }
        return m
    }
}
