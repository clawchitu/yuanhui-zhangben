import Foundation
import GRDB

// S22b 身份变化（§4.5、§4.6）：被踢、退出登录的排空、恢复队列、换 epoch。
//
// - 被踢 / 退出：当前会话退役（它的 epoch 存进会话行），清投影；未确认的 op 不动，成为恢复队列。
// - 恢复队列：按旧会话分组，用**旧令牌**、旧会话的 epoch 单独调 `/v1/sync`（`pull: false`），结果按**旧会话的店**记（§8 S22b）。
// - 换 epoch：清投影和游标（会话不动），记下新 epoch，把当前会话保留的已确认 op 重新标成待传，服务器按 id 幂等。

/// 为什么没有当前会话（启动时据此进 25b / 25f，或直接回登录页）
public enum SignOutReason: String, Sendable, Equatable {
    /// 家用手机被踢（25b）
    case kickedFamily = "kicked_family"
    /// 收银员手机被踢（25f）
    case kickedCashier = "kicked_cashier"
    /// 演示小店重置（`discard_outbox`）：outbox 已丢，回登录页
    case demoReset = "demo_reset"

    public static func kicked(_ role: Role) -> SignOutReason { role == .cashier ? .kickedCashier : .kickedFamily }
}

/// 退役会话（恢复队列的主人）的上传信息
public struct RetiredSession: Hashable, Sendable {
    public let session: LocalSession
    /// 这个会话所在店的 epoch（退役时存下；老库升级上来的为 nil，先用全零发、按 409 带回的握手）
    public let epoch: UUID?
    /// 主动退出登录时没传完：传完后要用旧令牌调 `logout`
    public let logoutPending: Bool
    /// 服务器已经说它被踢了（不用再调 `logout`）
    public let revoked: Bool
}

extension LocalDB {
    // MARK: - 退出原因

    public func signOutReason() throws -> SignOutReason? {
        try meta(.signedOutReason).flatMap(SignOutReason.init(rawValue:))
    }

    /// 25b / 25f「重新登录」之后不再显示
    public func clearSignOutReason() throws { try setMeta(.signedOutReason, nil) }

    // MARK: - 恢复队列

    /// 恢复队列一共几笔（25b / 25f、退出登录提示的「还有 N 笔没传」；收银员会话下只显示笔数，§14 S13-1）
    public func recoveryPendingCount() throws -> Int {
        try writer.read { db in
            let cur = try Self.currentSession(db)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM outbox WHERE status = 'pending' AND NOT (device_id = ? AND store_id = ?)
                """, arguments: [cur?.deviceId.uuidString ?? "", cur?.storeId.uuidString ?? ""]) ?? 0
        }
    }

    public func retiredSession(deviceId: UUID) throws -> RetiredSession? {
        try writer.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM session WHERE device_id = ? AND is_current = 0",
                                           arguments: [deviceId.uuidString]) else { return nil }
            return RetiredSession(session: try Self.sessionFrom(r), epoch: (r["epoch"] as String?).flatMap(UUID.init(uuidString:)),
                                  logoutPending: r["logout_pending"], revoked: r["revoked"])
        }
    }

    /// 恢复队列用旧令牌上传拿到 409：记下旧会话那家店的新 epoch 再发
    public func setRetiredEpoch(deviceId: UUID, _ epoch: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET epoch = ? WHERE device_id = ? AND is_current = 0",
                           arguments: [epoch.uuidString.lowercased(), deviceId.uuidString])
        }
    }

    /// 服务器说这个旧会话被踢了：传完不用再调 `logout`
    public func markRetiredRevoked(deviceId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET revoked = 1 WHERE device_id = ? AND is_current = 0", arguments: [deviceId.uuidString])
        }
    }

    /// 恢复队列里某个旧会话的下一批：≤200 个，按字节截断（同 `nextPushBatch`），按 seq
    public func nextRecoveryBatch(deviceId: UUID, storeId: UUID, maxOps: Int = LocalDB.maxBatchOps,
                                  maxBytes: Int = LocalDB.maxBatchBytes) throws -> PushBatch? {
        try writer.read { db in
            if let cur = try Self.currentSession(db), cur.deviceId == deviceId, cur.storeId == storeId { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ? ORDER BY seq LIMIT ?
                """, arguments: [deviceId.uuidString, storeId.uuidString, maxOps]).map(Self.outboxFrom)
            var out: [OutboxItem] = []
            var bytes = 0
            for o in rows {
                if !out.isEmpty && bytes + o.opJSON.count + 1 > maxBytes { break }
                bytes += o.opJSON.count + 1
                out.append(o)
            }
            return out.isEmpty ? nil : PushBatch(storeId: storeId, items: out)
        }
    }

    /// 恢复队列的请求体：旧会话的 epoch、只推不拉（`pull: false`，游标原样返回，手机不看）
    public static func recoveryRequestBody(_ batch: PushBatch, epoch: UUID?, appBuild: Int) -> Data {
        let e = (epoch ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))).uuidString.lowercased()
        var body = Data("{\"epoch\":\"\(e)\",\"cursors\":{\"catalog\":0,\"ledger\":0},\"app_build\":\(appBuild),\"pull\":false,\"ops\":[".utf8)
        for (i, o) in batch.items.enumerated() {
            if i > 0 { body.append(0x2C) }
            body.append(o.opJSON)
        }
        body.append(contentsOf: Array("]}".utf8))
        return body
    }

    /// 某个会话（设备 + 店）还有几笔没拿到结果（退出登录提示「还有 N 笔」，不受一批 200 的限制；PR #41 评审必须修 1）
    public func pendingCount(deviceId: UUID, storeId: UUID) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ?",
                             arguments: [deviceId.uuidString, storeId.uuidString]) ?? 0
        }
    }

    /// 还留着 op（待传或 14 天保留期内已确认的）的退役会话：令牌要留到这些 op 都清掉（换 epoch 后还要用它重传，§4.6）
    public func retiredSessionsWithRetainedOps() throws -> [RetiredSession] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM session s WHERE s.is_current = 0
                AND EXISTS (SELECT 1 FROM outbox o WHERE o.device_id = s.device_id AND o.store_id = s.store_id
                            AND o.status IN ('applied', 'held'))
                """).map { r in
                RetiredSession(session: try Self.sessionFrom(r), epoch: (r["epoch"] as String?).flatMap(UUID.init(uuidString:)),
                               logoutPending: r["logout_pending"], revoked: r["revoked"])
            }
        }
    }

    /// 退役会话那家店换了 epoch（§4.6）：记下新 epoch，把它保留的已确认 op（applied、held）重新标成待传，
    /// 由恢复队列用**它自己的旧令牌**重传（PR #41 评审必须修 2）。返回重新标成待传的笔数
    @discardableResult
    public func resetRetiredForEpoch(deviceId: UUID, _ epoch: UUID) throws -> Int {
        try writer.write { db in
            // 主动退出时已注销过的：重传完再注销一次（恢复后的库里这台设备可能还没注销）；被踢的不用（PR #41 第二轮 Fable ②）
            try db.execute(sql: """
                UPDATE session SET epoch = ?, logout_pending = CASE WHEN logged_out = 1 THEN 1 ELSE logout_pending END, logged_out = 0
                WHERE device_id = ? AND is_current = 0
                """, arguments: [epoch.uuidString.lowercased(), deviceId.uuidString])
            try db.execute(sql: """
                UPDATE outbox SET status = 'pending', reject_code = NULL, result_json = NULL, confirmed_at = NULL
                WHERE status IN ('applied', 'held') AND device_id = ?
                  AND device_id IN (SELECT device_id FROM session WHERE is_current = 0)
                """, arguments: [deviceId.uuidString])
            return db.changesCount
        }
    }

    /// 主动退出时推迟的 logout 已经调过了（之后不再调；令牌照样留到 op 清掉）
    public func markRetiredLoggedOut(deviceId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET logout_pending = 0, logged_out = 1 WHERE device_id = ? AND is_current = 0",
                           arguments: [deviceId.uuidString])
        }
    }

    // MARK: - 没记上的提示（§8 S22b「被拒的 op 在首页提示且不再重试」）

    /// 恢复队列被拒的笔数按**当次响应**累加（收银员会话下旧会话的 op 拿到结果就删，事后查不到）
    public func addRecoveryRejected(_ n: Int) throws {
        guard n > 0 else { return }
        try writer.write { db in
            let old = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                                              arguments: [MetaKey.recoveryRejectedUnseen.rawValue]) ?? "0") ?? 0
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [MetaKey.recoveryRejectedUnseen.rawValue, String(old + n)])
        }
    }

    /// 首页「N 笔没记上」：当前会话被拒、还没点过「知道了」的，加上恢复队列被拒的
    public func rejectedUnseenCount() throws -> Int {
        try writer.read { db in
            func m(_ k: MetaKey) throws -> String? {
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [k.rawValue])
            }
            let recovery = Int(try m(.recoveryRejectedUnseen) ?? "0") ?? 0
            guard let s = try Self.currentSession(db) else { return recovery }
            let own = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM outbox WHERE status = 'rejected' AND device_id = ? AND store_id = ? AND confirmed_at > ?
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString, try m(.rejectedSeenAt) ?? ""]) ?? 0
            return own + recovery
        }
    }

    /// 「知道了」：到此为止的被拒都看过了（之后被拒的再提示）
    public func acknowledgeRejected(at now: Date = Date()) throws {
        try writer.write { db in
            let seen = try String.fetchOne(db, sql: "SELECT MAX(confirmed_at) FROM outbox WHERE status = 'rejected'") ?? Op.formatTimestamp(now)
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [MetaKey.rejectedSeenAt.rawValue, seen])
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [MetaKey.recoveryRejectedUnseen.rawValue])
        }
    }

    // MARK: - 换 epoch（§4.6）

    /// 服务器换了 epoch（从备份恢复）：丢弃投影和游标，记下新 epoch，把当前会话**保留的已确认 op**（applied、held）重新标成待传，
    /// 一个事务。服务器上还在的按 id 幂等跳过，丢了的重新入账。被拒的不重发（「被拒的不再重试」）。
    /// 返回重新标成待传的笔数。
    @discardableResult
    public func resetForEpoch(_ epoch: UUID) throws -> Int {
        let n = try writer.write { db -> Int in
            let s = try Self.requireSession(db)
            try Self.clearProjection(db)
            // 退役会话保留的 op 不在这里重标：由恢复队列握手后当趟探测（只探钥匙串里还有令牌的会话，PR #41 第二轮 Fable ①）
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [MetaKey.serverEpoch.rawValue, epoch.uuidString.lowercased()])
            try db.execute(sql: """
                UPDATE outbox SET status = 'pending', reject_code = NULL, result_json = NULL, confirmed_at = NULL
                WHERE status IN ('applied', 'held') AND device_id = ? AND store_id = ?
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString])
            return db.changesCount
        }
        try compactIfPossible()
        return n
    }
}
