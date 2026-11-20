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

    /// 登录、兑码、换角色、换账号：开一个新会话。已有当前会话时，先清空**投影**（商品、条码、私有数据、
    /// 流水、批次头、保质期批次、游标、epoch），旧会话标为退役；**outbox 一条不动**，旧会话未确认的 op
    /// 就此成为恢复队列，仍绑定原来的店、设备和令牌（§3.4、§4.5）。
    public func beginSession(_ s: LocalSession, at now: Date = Date()) throws {
        let ts = Op.formatTimestamp(now)
        let hadSession = try writer.write { db -> Bool in
            let old = try Self.currentSession(db)
            if let old {
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
            return old != nil
        }
        if hadSession { try compact() }
    }

    /// 退出、被踢（没有新会话）：清投影，当前会话退役，outbox 不动。
    public func endSession(at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET is_current = 0, retired_at = ? WHERE is_current = 1",
                           arguments: [Op.formatTimestamp(now)])
            try Self.clearProjection(db)
        }
        try compact()
    }

    static func clearProjection(_ db: Database) throws {
        for t in LocalSchema.projectionTables { try db.execute(sql: "DELETE FROM \(t)") }
        for k in LocalSchema.projectionMetaKeys { try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [k.rawValue]) }
    }

    /// 清投影后把 WAL 并回主文件并截断、整理空闲页：换成收银员后，旧的进价不留在库文件的任何角落。
    func compact() throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            if db.configuration.readonly == false, (try String.fetchOne(db, sql: "PRAGMA journal_mode")) == "wal" {
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
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
