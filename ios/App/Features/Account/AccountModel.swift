import Foundation
import Observation
import ShopCore

/// S23b「账号与密码」（21a 下级页）和 23「注销账号」用到的网络调用。正常启动接 `APIClient`，令牌每次从钥匙串现取；
/// UI 测试接桩服务器（`-uiAPI`）
struct AccountBackend: Sendable {
    var changePassword: @Sendable (_ old: String, _ new: String) async throws -> Void
    var revokeOthers: @Sendable () async throws -> Int
    var cancelDeletion: @Sendable () async throws -> Void
    var me: @Sendable () async throws -> AccountMe

    static func live(api: APIClient, token: @escaping @Sendable () throws -> String) -> AccountBackend {
        AccountBackend(
            changePassword: { old, new in try await api.changePassword(old: old, new: new, token: try token()) },
            revokeOthers: { try await api.revokeOtherDevices(token: try token()) },
            cancelDeletion: { try await api.cancelAccountDeletion(token: try token()) },
            me: { try await api.me(token: try token()) }
        )
    }
}

/// 「账号与密码」页的状态：改密码、让其他手机全部退出、注销申请中时撤回
@MainActor @Observable
final class AccountModel {
    let backend: AccountBackend
    /// 现在几点（判断还能不能撤回）。服务器时间：手机时间 + 上次同步量出的偏差
    let now: () -> Date

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

    /// 注销状态（`delete_pending_until`）；页面一进来按本机记着的，再问一次 `/v1/me`
    private(set) var deletePendingUntil: String?
    private(set) var cancelling = false
    private(set) var cancelMessage: String?
    /// 注销状态变了（撤回成功、`/v1/me` 说的和本机不一样）：本机记下、同步跟着停 / 恢复推送
    var onDeletionChanged: ((String?) -> Void)?

    init(backend: AccountBackend, deletePendingUntil: String?, now: @escaping () -> Date) {
        self.backend = backend
        self.deletePendingUntil = deletePendingUntil
        self.now = now
    }

    private func clampField(_ k: ReferenceWritableKeyPath<AccountModel, String>) {
        let v = self[keyPath: k]
        let c = PasswordRule.clamp(v)
        if c != v { self[keyPath: k] = c }
    }

    var deletion: DeletionState { DeletionState.of(deletePendingUntil, now: now()) }

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

    /// 服务器回的码 → 一句话（改密码、申请注销共用；原密码输错的限速两边共用一个计数，§14 S03-8）
    static func text(_ f: AccountFailure, action: String) -> String {
        switch f {
        case .wrongPassword: return "密码不对，再输一次"
        case .rateLimited:
            return "密码错了太多次，\(f.waitMinutes ?? 15) 分钟以后再试"
        case .invalid: return "新密码要 \(PasswordRule.minLength) 到 \(PasswordRule.maxLength) 位"
        case .forbidden: return "这台手机不能\(action)"
        case .signedOut: return "这台手机已经退出登录了，重新登录后再\(action)"
        case .notDeletePending: return "账号不在注销中"
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

    // MARK: 注销状态

    /// 进页面问一次服务器（拿不到就用本机记着的）
    func refresh() async {
        guard let me = try? await backend.me() else { return }
        if me.deletePendingUntil != deletePendingUntil {
            deletePendingUntil = me.deletePendingUntil
            onDeletionChanged?(me.deletePendingUntil)
        }
    }

    /// 撤回注销（7 天内）。成功后本机清掉注销状态，同步恢复推送，留在本机的账自动补传
    func cancelDeletion() async {
        guard !cancelling, case .pending = deletion else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            try await backend.cancelDeletion()
            deletePendingUntil = nil
            cancelMessage = "已经撤回，账号照常用。没传上去的账会自动补传"
            onDeletionChanged?(nil)
        } catch {
            let f = AccountFailure(error)
            if f == .notDeletePending {
                // 已经撤回过了（别的手机撤的），或者过了 7 天：以服务器为准
                await refresh()
                cancelMessage = deletePendingUntil == nil ? "已经撤回了，账号照常用" : "已经过了 7 天，撤回不了"
            } else {
                cancelMessage = Self.text(f, action: "撤回")
            }
        }
    }

    /// 「12月2日 16:00」（上海时间）
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

/// 23 注销账号页的状态：再输一次密码，确认后先排空待传的账再申请（`AppModel.requestAccountDeletion`）
@MainActor @Observable
final class DeleteAccountModel {
    var password = "" {
        didSet { let c = PasswordRule.clamp(password); if c != password { password = c } }
    }
    private(set) var busy = false
    private(set) var message: String?
    private let submit: @MainActor (String) async -> AppModel.DeletionOutcome
    /// 申请成功（回登录页）或排空时发现被踢（进 25b / 25f）
    private let finished: @MainActor (AppModel.DeletionOutcome) -> Void

    init(submit: @escaping @MainActor (String) async -> AppModel.DeletionOutcome,
         finished: @escaping @MainActor (AppModel.DeletionOutcome) -> Void) {
        self.submit = submit
        self.finished = finished
    }

    var canSubmit: Bool { !busy && !password.isEmpty }

    func confirm() async {
        guard canSubmit else { return }
        busy = true
        message = nil
        let r = await submit(password)
        switch r {
        case .failed(let f):
            busy = false
            if f == .wrongPassword { password = "" }
            message = AccountModel.text(f, action: "注销")
        case .done, .kicked:
            password = ""
            finished(r)
        }
    }
}

extension AppModel {
    enum DeletionOutcome: Equatable {
        /// 申请成功：本机会话已结束，回登录页。带服务器给的 `delete_pending_until`
        case done(until: String)
        /// 排空时发现这台手机已经被踢：按被踢走（25b / 25f），没有发申请
        case kicked
        case failed(AccountFailure)
    }

    /// 「账号与密码」页的状态。没有网络服务（夹具没给桩）时为 nil，页面只出一句「要联网」
    func makeAccountModel() -> AccountModel? {
        guard let services else { return nil }
        let tokens = services.tokens, ref = session.tokenRef
        let backend = AccountBackend.live(api: services.api) {
            guard let t = try tokens.token(ref: ref) else { throw DeviceBackend.NoToken() }
            return t
        }
        let m = AccountModel(backend: backend, deletePendingUntil: figures.deletePendingUntil,
                             now: { [weak self] in Date().addingTimeInterval(self?.clockOffset ?? 0) })
        m.onDeletionChanged = { [weak self] until in self?.setDeletePending(until) }
        return m
    }

    /// 注销状态变了：本机记下（同步引擎据此停推 / 恢复推送，§14 S04-2），首页提醒条跟着变；撤回了就马上同步一趟补传
    func setDeletePending(_ until: String?) {
        figures.deletePendingUntil = until
        let db = db
        Task {
            await Task.detached(priority: .userInitiated) { try? db.setMeta(.deletePendingUntil, until) }.value
            if until == nil { self.sync?.kick() }
        }
    }

    /// 23「确认注销」：
    /// 1. 先按 S22b 的排空规则把待传的账传上去（申请以后服务器一笔都不应用，§4.2、§14 S04-2）。排空时发现已经被踢 → 不申请，按被踢走；
    /// 2. 申请（`POST /v1/account/delete-request`，要再输一次密码）。没成功：同步照常接着跑，留在这页；
    /// 3. 成功：服务器已经让这家店的全部手机退出（含本机，令牌作废）。本机会话结束（清投影）、回登录页。
    ///    还没传上去的（排空时没网等）留在恢复队列：注销期间服务器不应用、手机留着；7 天内撤回后用旧令牌补传，
    ///    按被退出手机的补传处理（卖出带补传标记入账、别的等家里人确认，§4.5、§4.4 注销一行）。
    func requestAccountDeletion(password: String) async -> DeletionOutcome {
        guard let services, let token = try? services.tokens.token(ref: session.tokenRef) else { return .failed(.signedOut) }
        let api = services.api
        return await requestAccountDeletion { try await api.requestAccountDeletion(password: password, token: token) }
    }

    /// 同上，发申请的那一下由调用方给（单元测试换成假的）
    func requestAccountDeletion(send: @escaping () async throws -> String) async -> DeletionOutcome {
        if await drainOutbox() { return .kicked }
        let until: String
        do {
            until = try await send()
        } catch {
            resumeSync()
            return .failed(AccountFailure(error))
        }
        sync?.stop()
        sync?.onSignedOut = nil
        let db = db, deviceId = session.deviceId, storeId = session.storeId
        await Task.detached(priority: .userInitiated) { () -> Void in
            let pending = (try? db.pendingCount(deviceId: deviceId, storeId: storeId)) ?? 1
            // 令牌服务器已经作废：按被退出记（恢复队列不再调 logout），没传完的留着等撤回后补传
            try? db.endSession(revoked: true)
            if pending == 0 { try? db.markRetiredLoggedOut(deviceId: deviceId) }
        }.value
        return .done(until: until)
    }
}
