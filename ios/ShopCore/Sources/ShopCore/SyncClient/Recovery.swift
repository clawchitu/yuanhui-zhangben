import Foundation

// S22b 恢复队列的上传（§4.5）：以前的会话留下的未确认 op，用**它自己的旧令牌**单独调 `/v1/sync`（只推不拉），
// 每次打开 App、每次同步、兑码成功后第一次拉取之前都试一遍，传不完不拦。
//
// - 结果按**发送那批 op 的旧会话的店**记（`recordResults(storeId: 旧店)`，op id 只在店内唯一，§8 S22b）。
// - 当前会话是收银员时，旧会话的 op 一拿到结果就删（`recordResults` 里做），之后读不回结果；被拒的笔数按**当次响应**累加。
// - 409：旧会话那家店换了 epoch，记下新的再发（op 按 id 幂等）。401：旧令牌已经不认了（店清除了等），这组停下、留着。
// - `discard_outbox`（演示店重置）：丢弃这家店的 outbox 和恢复队列，不重放。
// - 一个旧会话传完：主动退出时推迟的 `logout` 这时用旧令牌调（被踢的不用调）；然后删钥匙串里的旧令牌、删会话行。
//
// 方法同步阻塞（会开写事务、压缩），不许在主线程调。

/// 恢复队列要发的请求
public enum RecoveryCall: Sendable, Equatable {
    case sync(token: String, body: Data)
    case logout(token: String)
}

/// 一趟恢复上传的结果（调用方据此刷新笔数、首页提示）
public struct RecoveryReport: Equatable, Sendable {
    /// 拿到结果的笔数
    public var resolved = 0
    /// 这趟里被拒的笔数（来自响应）
    public var rejected = 0
    /// 这趟里暂存待确认的笔数（被踢设备的进货等）
    public var held = 0
    /// 传完、删了令牌的旧会话
    public var finished: [UUID] = []
    /// 有店的 outbox 因演示店重置被丢弃
    public var discarded = false
    /// 还剩几笔没传
    public var remaining = 0
    /// 要求探测 epoch、但有会话没探成（连不上、5xx）：下趟再探
    public var probeIncomplete = false
    public init() {}
}

public final class RecoveryUploader: Sendable {
    public typealias Send = @Sendable (RecoveryCall) throws -> (Int, Data)
    let db: LocalDB
    let tokens: any TokenStore
    let appBuild: Int
    let send: Send
    /// 探测这趟里有店因演示重置被丢弃（只在 `run` 的同一线程里读写）
    nonisolated(unsafe) private var discarded = false

    public init(db: LocalDB, tokens: any TokenStore, appBuild: Int, send: @escaping Send) {
        self.db = db; self.tokens = tokens; self.appBuild = appBuild; self.send = send
    }

    /// 传一遍。连不上（`send` 抛错）就停下抛出，已经拿到的结果已提交；调用方不因此拦任何东西。
    /// `probeEpochs`：先给每个还留着已确认 op 的旧会话发一个空请求看它那家店换没换 epoch，换了就把保留的 op 重新标成待传
    /// （§4.6；当前会话的握手只覆盖同一家店的旧会话）。调用方按需打开（每次启动一次），免得每趟同步都多发请求。
    @discardableResult
    public func run(maxRounds: Int = 50, probeEpochs: Bool = false) throws -> RecoveryReport {
        var report = RecoveryReport()
        defer { report.remaining = (try? db.recoveryPendingCount()) ?? 0 }
        // 补做没做成的压缩（只跑恢复上传、没有当前会话时也要做，§3.4）；14 天到期的已确认 op 清掉（§4.6）
        do { try db.compactIfNeeded() } catch LocalDBError.compactionBusy {}
        try db.purgeConfirmed()
        if probeEpochs {
            report.probeIncomplete = try !probe()
            if discarded { report.discarded = true }
        }
        for g in try db.recoveryQueue() {
            try upload(g, report: &report, maxRounds: maxRounds)
        }
        try finishDrained(&report)
        report.remaining = try db.recoveryPendingCount()
        return report
    }

    func upload(_ g: RecoveryGroup, report: inout RecoveryReport, maxRounds: Int) throws {
        // 钥匙串里没有旧令牌（重装、换机恢复）：传不上去，留着（不删，不丢账）
        guard let token = try tokens.token(ref: g.tokenRef) else { return }
        var epoch = try db.retiredSession(deviceId: g.deviceId)?.epoch
        var handshakes = 0
        for _ in 0..<maxRounds {
            guard let batch = try db.nextRecoveryBatch(deviceId: g.deviceId, storeId: g.storeId) else { return }
            let (code, data) = try send(.sync(token: token, body: LocalDB.recoveryRequestBody(batch, epoch: epoch, appBuild: appBuild)))
            if code == 409 {
                guard handshakes < 2, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let e = (obj["epoch"] as? String).flatMap(UUID.init(uuidString:)) else { return }
                handshakes += 1
                epoch = e
                // 换了 epoch：它保留的已确认 op 也一起重传（服务器按 id 幂等）
                try db.resetRetiredForEpoch(deviceId: g.deviceId, e)
                continue
            }
            guard code == 200 else { return }  // 401（旧令牌不认了）、5xx：这组先停
            let r = try SyncResponse.decode(data)
            if r.device.discardOutbox == true {
                for ref in try db.discardOutbox(storeId: g.storeId) { tokens.delete(ref: ref) }
                tokens.delete(ref: g.tokenRef)
                report.discarded = true
                return
            }
            if r.device.revoked { try db.markRetiredRevoked(deviceId: g.deviceId) }
            // 注销期间：一个都不应用、results 为空，留着等撤回（§14 S04-2）
            guard r.deletePendingUntil == nil, !r.results.isEmpty else { return }
            let results = r.results.compactMap { x -> OpResult? in
                guard let st = OutboxItem.Status(rawValue: x.status) else { return nil }
                return try? OpResult(id: x.id, status: st, code: x.code)
            }
            // 店 = 发送这批 op 的旧会话的店，不是当前会话的店
            try db.recordResults(results, storeId: g.storeId)
            // 提示用这次响应里的数（收银员会话下这些 op 已经删了，读不回）
            let rejected = results.filter { $0.status == .rejected }.count
            try db.addRecoveryRejected(rejected)
            report.resolved += results.count
            report.rejected += rejected
            report.held += results.filter { $0.status == .held }.count
        }
    }

    /// 还留着已确认 op 的旧会话：发一个空请求（只推不拉）看它那家店的 epoch，不一致就重标保留的 op
    /// 返回 false = 有会话没探成（5xx 等），调用方下趟再探。连不上直接抛出（同样算没探成）
    @discardableResult
    func probe() throws -> Bool {
        var complete = true
        discarded = false
        for r in try db.retiredSessionsWithRetainedOps() {
            // 钥匙串里没有令牌的不重标：重标了也传不上去，只会让库存多算、「N 笔没传」不归零
            guard let token = try tokens.token(ref: r.session.tokenRef) else { continue }
            let empty = PushBatch(storeId: r.session.storeId, items: [])
            let (code, data) = try send(.sync(token: token, body: LocalDB.recoveryRequestBody(empty, epoch: r.epoch, appBuild: appBuild)))
            if code == 409, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = (obj["epoch"] as? String).flatMap(UUID.init(uuidString:)) {
                try db.resetRetiredForEpoch(deviceId: r.session.deviceId, e)
            } else if code == 200, let resp = try? SyncResponse.decode(data), resp.device.discardOutbox == true {
                // 演示店重置：这家店的 op 和令牌都丢掉（PR #41 第二轮 Codex 可选）
                for ref in try db.discardOutbox(storeId: r.session.storeId) { tokens.delete(ref: ref) }
                tokens.delete(ref: r.session.tokenRef)
                discarded = true
            } else if code != 200 && code != 401 {
                complete = false
            }
        }
        return complete
    }

    /// 恢复队列清空的旧会话：推迟的 `logout` 现在调（§4.5「传完才注销」）。旧令牌和会话行留到它的 op 全部清掉
    /// （14 天保留期，换 epoch 后要用它重传，PR #41 必须修 2）才删
    func finishDrained(_ report: inout RecoveryReport) throws {
        for s in try db.retiredSessionsWithoutPendingOps() {
            let info = try db.retiredSession(deviceId: s.deviceId)
            if info?.logoutPending == true, info?.revoked != true, let token = try tokens.token(ref: s.tokenRef) {
                let (code, _) = try send(.logout(token: token))
                // 204 = 注销了；401 = 令牌已经不认了。别的（5xx）下次再试
                guard code == 204 || code == 200 || code == 401 else { continue }
                try db.markRetiredLoggedOut(deviceId: s.deviceId)
                report.finished.append(s.deviceId)
            }
            guard try db.retiredSessionsWithRetainedOps().contains(where: { $0.session.deviceId == s.deviceId }) == false else { continue }
            tokens.delete(ref: s.tokenRef)
            try db.forgetSession(deviceId: s.deviceId)
            if !report.finished.contains(s.deviceId) { report.finished.append(s.deviceId) }
        }
    }
}
