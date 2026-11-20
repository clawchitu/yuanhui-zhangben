import Foundation
import GRDB

/// 一次登录 / 兑码得到的会话（§4.5「当前会话」）。令牌本身在钥匙串里，这里只记条目名 `tokenRef`。
public struct LocalSession: Hashable, Sendable {
    public let deviceId: UUID
    public let storeId: UUID
    public let role: Role
    public let tokenRef: String
    public let storeName: String
    public let deviceLabel: String

    public init(deviceId: UUID, storeId: UUID, role: Role, tokenRef: String, storeName: String, deviceLabel: String) throws {
        guard role != .revoked else { throw invalid("被踢的设备不能开新会话") }
        guard !tokenRef.isEmpty else { throw invalid("令牌引用不能为空") }
        self.deviceId = deviceId; self.storeId = storeId; self.role = role; self.tokenRef = tokenRef
        self.storeName = storeName; self.deviceLabel = deviceLabel
    }

    /// 收银员手机：不存进价、库存、批次
    public var holdsPrivateData: Bool { role != .cashier }
}

/// 本地库测试用的崩溃注入点（S13 验收「记账的原子性」）。
public enum LocalDBFaultPoint: Sendable {
    /// 流水和批次头已写、outbox 还没写
    case afterEntriesBeforeOutbox
    /// 换身份（清投影、换会话）的事务已提交、压缩还没做
    case afterIdentitySwitchBeforeCompact
    /// 压缩（VACUUM + 截断 WAL）已做成、「待压缩」标记还没清
    case afterCompactBeforeClearingMark
    /// `recordResults` 的事务已提交（可能刚记下「待压缩」）、它自己的压缩还没开始
    case afterResultsBeforeCompact
}

public enum LocalDBError: Error, Equatable, Sendable {
    /// 压缩（VACUUM + 截断 WAL）被还开着的读事务挡住，重试后仍没做成。「待压缩」标记保留，下次同步或下次打开时再做
    case compactionBusy
}


/// 手机本地库（§3.4，GRDB）。所有写入都在一个事务里完成；记一笔账 = 写流水 + 写 outbox，同一个事务（§4.1 第 6 条）。
public final class LocalDB: Sendable {
    public let writer: any DatabaseWriter
    let faultHook: (@Sendable (LocalDBFaultPoint) throws -> Void)?

    /// 打开（不存在就新建）库文件并跑迁移。WAL 模式；`secure_delete` 打开，清投影后删掉的进价不留在空闲页里。
    public convenience init(path: String, faultHook: (@Sendable (LocalDBFaultPoint) throws -> Void)? = nil) throws {
        try self.init(writer: try DatabasePool(path: path, configuration: LocalDB.configuration()), faultHook: faultHook)
    }

    /// 内存库（预览、单元测试）
    public static func inMemory() throws -> LocalDB {
        try LocalDB(writer: try DatabaseQueue(configuration: configuration()), faultHook: nil)
    }

    init(writer: any DatabaseWriter, faultHook: (@Sendable (LocalDBFaultPoint) throws -> Void)?) throws {
        self.writer = writer
        self.faultHook = faultHook
        try LocalSchema.migrator().migrate(writer)
        // 上次换身份后压缩没做完（进程被杀、被读事务挡住）：先补做。还挡住就留着标记，不拦打开
        try compactIfPossible()
    }

    static func configuration() -> Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return c
    }

    // MARK: - 会话与身份变化（§4.5）

    /// 当前会话；没登录时为 nil
    public func currentSession() throws -> LocalSession? {
        try writer.read { try Self.currentSession($0) }
    }

    static func currentSession(_ db: Database) throws -> LocalSession? {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM session WHERE is_current = 1") else { return nil }
        return try sessionFrom(r)
    }

    static func sessionFrom(_ r: Row) throws -> LocalSession {
        guard let role = Role(rawValue: r["role"]) else { throw invalid("库里的角色不认识") }
        return try LocalSession(deviceId: try parseUUID(r["device_id"]), storeId: try parseUUID(r["store_id"]), role: role,
                                tokenRef: r["token_ref"], storeName: r["store_name"], deviceLabel: r["device_label"])
    }

    static func requireSession(_ db: Database) throws -> LocalSession {
        guard let s = try currentSession(db) else { throw invalid("还没登录，不能记账") }
        return s
    }

    /// 登录、兑码、换角色、换账号：开一个新会话。先清空**投影**（商品、条码、私有数据、流水、批次头、
    /// 保质期批次、游标、epoch），已有的当前会话标为退役；**未确认的 op 一条不动**，旧会话未确认的 op
    /// 就此成为恢复队列，仍绑定原来的店、设备和令牌（§3.4、§4.5）。
    ///
    /// 新会话是收银员时，旧会话**已确认**的 op 立刻删掉，不留 14 天（§14 S13-1）。不论之前有没有当前会话
    /// （家用退出或被踢之后再扫收银员码时没有）都这样做。清投影的同一个事务里记下「待压缩」，压缩做成才清掉。
    public func beginSession(_ s: LocalSession, at now: Date = Date()) throws {
        let ts = Op.formatTimestamp(now)
        try writer.write { db in
            if let old = try Self.currentSession(db) {
                guard old.deviceId != s.deviceId else { throw invalid("设备 id 每次登录都要新生成（§3.1）") }
                try db.execute(sql: "UPDATE session SET is_current = 0, retired_at = ? WHERE device_id = ?",
                               arguments: [ts, old.deviceId.uuidString])
            }
            try Self.clearProjection(db)
            try db.execute(sql: """
                INSERT INTO session (device_id, store_id, role, token_ref, store_name, device_label, is_current, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString, s.role.rawValue, s.tokenRef,
                                 s.storeName, s.deviceLabel, ts])
            try Self.deleteConfirmedForeignOps(db, current: s)
        }
        try faultHook?(.afterIdentitySwitchBeforeCompact)
        try compactIfPossible()
    }

    /// 退出、被踢（没有新会话）：清投影，当前会话退役，outbox 不动。
    public func endSession(at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET is_current = 0, retired_at = ? WHERE is_current = 1",
                           arguments: [Op.formatTimestamp(now)])
            try Self.clearProjection(db)
        }
        try faultHook?(.afterIdentitySwitchBeforeCompact)
        try compactIfPossible()
    }

    /// 清投影，并在同一个事务里记下「待压缩」
    static func clearProjection(_ db: Database) throws {
        for t in LocalSchema.projectionTables { try db.execute(sql: "DELETE FROM \(t)") }
        for k in LocalSchema.projectionMetaKeys { try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [k.rawValue]) }
        try markCompactionPending(db)
    }

    /// 当前会话是收银员时，删掉不属于当前会话的已确认 op（连同 `outbox_effect`）并记下「待压缩」。
    /// 未确认的不删：它们是恢复队列，传完（拿到结果）才删（§14 S13-1）。
    static func deleteConfirmedForeignOps(_ db: Database, current s: LocalSession) throws {
        guard !s.holdsPrivateData else { return }
        try db.execute(sql: "DELETE FROM outbox WHERE status <> 'pending' AND NOT (device_id = ? AND store_id = ?)",
                       arguments: [s.deviceId.uuidString, s.storeId.uuidString])
        if db.changesCount > 0 { try markCompactionPending(db) }
    }

    static func markCompactionPending(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, '1') ON CONFLICT(key) DO NOTHING",
                       arguments: [MetaKey.compactPending.rawValue])
    }

    // MARK: - 压缩：删掉的进价不留在库文件的任何角落

    /// 截断 WAL 被读事务挡住时重试几次（间隔逐次加长，合计约 0.3 秒）
    static let compactionAttempts = 5

    /// 还有没做完的压缩（「待压缩」标记还在）
    public func needsCompaction() throws -> Bool { try meta(.compactPending) != nil }

    /// 有「待压缩」标记就补做。同步引擎每次同步时调用；被读事务挡住、重试后仍没做成就抛 `LocalDBError.compactionBusy`，标记保留。
    public func compactIfNeeded() throws {
        guard try compactIfPossible() else { throw LocalDBError.compactionBusy }
    }

    /// 返回 false = 被读事务挡住，标记保留（身份变化本身已提交，不因此报错；下次同步或打开时再做）。
    @discardableResult
    func compactIfPossible() throws -> Bool {
        guard try needsCompaction() else { return true }
        for attempt in 0..<Self.compactionAttempts {
            if attempt > 0 { usleep(UInt32(30_000 * attempt)) }
            if try compactOnce() { return true }
        }
        return false
    }

    /// 在**同一段**串行写访问里：VACUUM 整理掉空闲页，把 WAL 并回主文件并截断为 0，确认做成后清「待压缩」标记。
    /// 别的线程的写（例如 `recordResults` 删旧进货 op 并记标记）只能排在这一段之前或之后：之前的被这次 VACUUM 覆盖，
    /// 之后的重新记下标记、由它自己补做，不会被这里误清（Codex 第二轮 P1）。清标记在截断之后：在这之前死掉，
    /// 下次打开会再做一遍（重做无害）。
    ///
    /// GRDB 的 `checkpoint(.truncate)` 在被读者挡住时抛 `SQLITE_BUSY`（`PRAGMA wal_checkpoint` 只在结果行里返回
    /// busy = 1，不报错），这里据此返回 false，标记保留。
    func compactOnce() throws -> Bool {
        try writer.writeWithoutTransaction { db in
            guard try Self.compactPending(db) else { return true }
            do {
                try db.execute(sql: "VACUUM")
                if try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal" {
                    let r = try db.checkpoint(.truncate)
                    guard r.walFrameCount == 0 || r.walFrameCount == r.checkpointedFrameCount else { return false }
                }
            } catch let e as DatabaseError where e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED {
                return false
            }
            try faultHook?(.afterCompactBeforeClearingMark)
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [MetaKey.compactPending.rawValue])
            return true
        }
    }

    static func compactPending(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM meta WHERE key = ?)",
                          arguments: [MetaKey.compactPending.rawValue]) ?? false
    }

    // MARK: - meta

    public func meta(_ key: MetaKey) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key.rawValue]) }
    }

    public func setMeta(_ key: MetaKey, _ value: String?) throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [key.rawValue, value])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key.rawValue])
            }
        }
    }
}

func parseUUID(_ s: String) throws -> UUID {
    guard let u = UUID(uuidString: s) else { throw invalid("库里的 id 不是 UUID：\(s)") }
    return u
}
