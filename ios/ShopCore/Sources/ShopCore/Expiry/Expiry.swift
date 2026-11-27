import Foundation
import GRDB

// S27 保质期（§5.4、设计稿 19 / 20 / 20b、01 黄条）：提醒规则、19 的清单、处理（20 / 20b）记进 outbox。
// 清单和首页黄条只看本机：拉下来的未关闭批次（`lot`，仅家用号）+ 本机还没传上去的处理 / 再提醒（叠加在上面），
// 所以没网也能看、处理完马上从清单和黄条里消失。处理一律以人数的为准（actual_qty），服务器按 handle_ver 防两台手机各处理一次。

extension CalendarDate {
    /// 公历日序号（只用来相减、加天数）：Fliegel–Van Flandern 儒略日，整数算
    public var dayNumber: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// 日序号 → 日期（`dayNumber` 的反函数）
    public init(dayNumber jd: Int) throws {
        let a = jd + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        try self.init(year: 100 * b + d - 4800 + m / 10, month: m + 3 - 12 * (m / 10), day: e - (153 * m + 2) / 5 + 1)
    }

    /// 加天数（可为负）。超出 0001–9999 年抛错
    public func adding(days: Int) throws -> CalendarDate { try CalendarDate(dayNumber: dayNumber + days) }

    /// 从 self 到 other 差几天（other 晚为正）
    public func days(until other: CalendarDate) -> Int { other.dayNumber - dayNumber }
}

/// 提醒规则（§5.4，和服务器 `lots.ts` 的 `shouldRemind`、`contracts/vectors/expiry.json` 的 remind 组一致）
public enum ExpiryRule {
    /// `今天 >= 到期日 − 提前天数`，批次未关闭、`qty_left > 0`、不在「过几天再提醒」期内（`今天 < snoozed_until` 才算在期内，
    /// 到 `snoozed_until` 当天就恢复提醒）。没填到期日的不提醒。
    public static func shouldRemind(today: CalendarDate, expiry: CalendarDate?, warnDays: Int64, qtyLeft: Int64,
                                    closed: Bool, snoozedUntil: CalendarDate?) -> Bool {
        guard let expiry, !closed, qtyLeft > 0 else { return false }
        if let s = snoozedUntil, today < s { return false }
        // 提前天数上限 3650（Limits），减出来不会越界；越界的到期日当作「早就该提醒」
        guard let from = try? expiry.adding(days: -Int(warnDays)) else { return true }
        return today >= from
    }

    /// 「还在卖，过几天再提醒」固定 3 天（20 / 20b）
    public static let snoozeDays: Int64 = 3
}

/// 19 上的一行：一个要提醒（或在再提醒期内）的批次
public struct ExpiryItem: Hashable, Sendable, Identifiable {
    public let lotId: UUID
    public let productId: UUID
    public let name: String
    public let unit: String
    public let imageVer: Int
    public let expiryDate: CalendarDate
    /// 账上的批次剩余（推算的，处理时以人数的为准）；本机有没传的「再提醒」时是那次填的实际数
    public let qtyLeft: Int64
    /// 服务器上的批次版本（处理 / 再提醒带上去，防两台手机各处理一次）
    public let handleVer: Int64
    /// 在「过几天再提醒」期内时是哪天恢复提醒；不在期内为 nil
    public let snoozedUntil: CalendarDate?
    /// 到期日 − 今天：负数 = 过了几天，0 = 今天到期
    public let daysLeft: Int
    public var id: UUID { lotId }
    /// 已过期：到期日早于今天（今天到期的还算「快过期」，还能卖到今天）
    public var expired: Bool { daysLeft < 0 }
}

/// 19 的三段：已过期 / 快过期 / 过几天再提醒的。前两段按到期日排（同日按名称），第三段按恢复提醒的日子排
public struct ExpiryBoard: Hashable, Sendable {
    public let today: CalendarDate
    public let expired: [ExpiryItem]
    public let soon: [ExpiryItem]
    public let snoozed: [ExpiryItem]
    /// 首页黄条、各段标题的「N 样」：数的是商品种数（§5.4）
    public static func kinds(_ items: [ExpiryItem]) -> Int { Set(items.map(\.productId)).count }
    /// 首页黄条：要提醒的商品种数（已过期 + 快过期，按商品合并）
    public var remindKinds: Int { Self.kinds(expired + soon) }
    public var isEmpty: Bool { expired.isEmpty && soon.isEmpty && snoozed.isEmpty }
}

/// 处理面板（20 / 20b）的几个选择
public enum ExpiryChoice: String, Hashable, Sendable, CaseIterable {
    case soldOut, discard, `return`, snooze

    /// 面板上从上到下的顺序，第一个是突出的那个：已过期突出「下架扔掉」（20），没过期突出「还在卖，过几天再提醒」（20b），
    /// 实际数减到 0 时突出「卖完了」并把扔掉、退货置灰
    public static func order(expired: Bool, actualQty: Int64) -> [ExpiryChoice] {
        if actualQty <= 0 { return [.soldOut, .snooze, .discard, .return] }
        return expired ? [.discard, .soldOut, .return, .snooze] : [.snooze, .soldOut, .return, .discard]
    }

    /// 能不能点：实际数为 0 时扔掉、退货不能点（没东西可扣）
    public func enabled(actualQty: Int64) -> Bool {
        switch self {
        case .discard, .return: actualQty > 0
        case .soldOut, .snooze: true
        }
    }
}

/// 「下架扔掉」算亏多少（20 上的「算亏 ¥19.60」）：按本机的进价基线，用和服务器 `cost.ts` `takeCost` 同一个算法（§5.2）。
/// 只是预计（没传的卖出、别的手机刚进的货不在基线里），记账以服务器为准。进价不知道（`k` 为假）时没有，不显示。
public enum ExpiryLoss {
    public static func estimate(_ b: ProductPrivate, qty: Int64) throws -> Fen? {
        guard b.costKnown, qty > 0 else { return nil }
        let q = b.stockQty, v = b.stockValueFen.raw
        if q > 0 {
            let u = try roundDiv(v, q)
            let take = min(qty, q)
            let first = take == q ? v : try roundDiv(try Checked.mul(v, take), q)
            return Fen(try Checked.add(first, try Checked.mul(qty - take, u)))
        }
        guard let c = b.lastCostFen else { return nil }
        return Fen(try Checked.mul(qty, c.raw))
    }
}

extension LocalDB {
    /// 19 的清单：本机的未关闭批次，叠上本机没传的处理（处理了的不再出现）和再提醒（按那次填的数和天数）。
    /// 停用的商品、没填到期日的批次不列（和服务器 09 的「快过期了」一致）。收银员手机没有批次，返回空。
    public func expiryBoard(today: CalendarDate) throws -> ExpiryBoard {
        try writer.read { db in
            guard let s = try Self.currentSession(db), s.holdsPrivateData else {
                return ExpiryBoard(today: today, expired: [], soon: [], snoozed: [])
            }
            // 本机还没传上去的处理 / 再提醒（同一家店，含恢复队列里的），按 outbox 顺序，后面的盖前面的
            var disposed = Set<UUID>()
            var snoozes: [UUID: (qty: Int64, until: CalendarDate)] = [:]
            // 本机没传的「再提醒」条数：服务器每应用一条 handle_ver + 1，之后再处理同一批要带加上去的版本，否则被拒 stale
            var pendingHandles: [UUID: Int64] = [:]
            let pending = try Row.fetchAll(db, sql: """
                SELECT type, op_json, occurred_at FROM outbox WHERE store_id = ? AND status = 'pending' AND type IN ('expiry_dispose', 'lot_snooze')
                ORDER BY seq
                """, arguments: [s.storeId.uuidString])
            struct LotOp: Decodable {
                struct P: Decodable { let lot_id: UUID; let actual_qty: Int64; let days: Int? }
                let payload: P
            }
            for r in pending {
                guard let p = (try? JSONDecoder().decode(LotOp.self, from: r["op_json"] as Data))?.payload else { continue }
                let lot = p.lot_id
                if r["type"] as String == OpType.expiryDispose.rawValue {
                    disposed.insert(lot)
                    continue
                }
                pendingHandles[lot, default: 0] += 1
                if let days = p.days, let at = Self.parseTimestamp(r["occurred_at"] as String),
                          let until = try? Self.shanghaiDay(at).adding(days: days) {
                    let qty = p.actual_qty
                    // 和服务器一样：op 时间所在的上海日期 + 天数（§14 S06-5；服务器还会按时钟校正，差几分钟跨零点时差一天，只影响提醒早晚）
                    snoozes[lot] = (qty, until)
                }
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.product_id, l.expiry_date, l.qty_left, l.snoozed_until, l.handle_ver,
                       p.name, p.base_unit, p.image_ver, COALESCE(pp.expiry_warn_days, 7) AS warn
                FROM lot l JOIN product p ON p.id = l.product_id
                LEFT JOIN product_private pp ON pp.product_id = l.product_id
                WHERE l.expiry_date IS NOT NULL AND p.archived = 0
                """)
            var expired: [ExpiryItem] = [], soon: [ExpiryItem] = [], snoozed: [ExpiryItem] = []
            for r in rows {
                let lotId = try parseUUID(r["id"])
                guard !disposed.contains(lotId), let expiry = try? CalendarDate(r["expiry_date"] as String) else { continue }
                var qty: Int64 = r["qty_left"]
                var until = (r["snoozed_until"] as String?).flatMap { try? CalendarDate($0) }
                if let o = snoozes[lotId] { qty = o.qty; until = o.until }
                let warn: Int64 = r["warn"]
                let item = ExpiryItem(lotId: lotId, productId: try parseUUID(r["product_id"]), name: r["name"], unit: r["base_unit"],
                                      imageVer: r["image_ver"], expiryDate: expiry, qtyLeft: qty, handleVer: (r["handle_ver"] as Int64) + pendingHandles[lotId, default: 0],
                                      snoozedUntil: until.flatMap { today < $0 ? $0 : nil }, daysLeft: today.days(until: expiry))
                if ExpiryRule.shouldRemind(today: today, expiry: expiry, warnDays: warn, qtyLeft: qty, closed: false, snoozedUntil: until) {
                    if item.expired { expired.append(item) } else { soon.append(item) }
                } else if item.snoozedUntil != nil, qty > 0 {
                    snoozed.append(item)
                }
            }
            let byExpiry: (ExpiryItem, ExpiryItem) -> Bool = {
                ($0.expiryDate, $0.name, $0.lotId.uuidString) < ($1.expiryDate, $1.name, $1.lotId.uuidString)
            }
            return ExpiryBoard(today: today, expired: expired.sorted(by: byExpiry), soon: soon.sorted(by: byExpiry),
                               snoozed: snoozed.sorted { ($0.snoozedUntil!, $0.expiryDate, $0.name) < ($1.snoozedUntil!, $1.expiryDate, $1.name) })
        }
    }

    /// 处理一个批次（20 / 20b）：写 op 进 outbox，扔掉 / 退货顺带记库存增减（本机显示的库存马上少）。
    /// 不写本地流水：扔掉 / 退货的流水由服务器生成，下一趟同步拉下来（记的账里能撤）。
    /// 「还在卖，过几天再提醒」是 `lot_snooze`；其余三种是 `expiry_dispose`（卖完了不记流水，但 entry_id 照填，契约要求）。
    /// 返回 op id，界面等这趟同步的结果（被拒 stale = 别的手机已经处理过这批）。
    @discardableResult
    public func handleExpiry(_ item: ExpiryItem, choice: ExpiryChoice, actualQty: Int64, opId: UUID = UUID(),
                             entryId: UUID = UUID(), at now: Date = Date()) throws -> UUID {
        guard choice.enabled(actualQty: actualQty) else { throw invalid("实际数为 0 时不能扔掉或退货") }
        let payload: any OpPayload
        var effects: [StockEffect] = []
        switch choice {
        case .snooze:
            payload = try LotSnoozePayload(lotId: item.lotId, handleVer: item.handleVer, actualQty: actualQty, days: ExpiryRule.snoozeDays)
        case .soldOut, .discard, .return:
            let action: ExpiryDisposePayload.Action = choice == .soldOut ? .soldOut : choice == .discard ? .discard : .return
            payload = try ExpiryDisposePayload(lotId: item.lotId, handleVer: item.handleVer, actualQty: actualQty, action: action,
                                               entryId: entryId)
            if choice != .soldOut { effects.append(StockEffect(productId: item.productId, qtyDelta: -actualQty)) }
        }
        let op = Op(id: opId, occurredAt: now, payload: payload)
        try enqueue(op, effects: effects)
        return opId
    }

    /// 一条 op 现在的结果（界面等处理结果用）：还没传为 pending；找不到为 nil
    public func opStatus(_ id: UUID) throws -> (status: OutboxItem.Status, code: String?)? {
        try writer.read { db in
            guard let s = try Self.currentSession(db),
                  let r = try Row.fetchOne(db, sql: "SELECT status, reject_code FROM outbox WHERE store_id = ? AND id = ?",
                                           arguments: [s.storeId.uuidString, id.uuidString]),
                  let st = OutboxItem.Status(rawValue: r["status"]) else { return nil }
            return (st, r["reject_code"])
        }
    }
}
