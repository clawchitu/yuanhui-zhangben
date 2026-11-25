import Foundation
import GRDB

/// 选图、拍照上传能不能发了（S22d）：服务器上要先有这个商品（它的 `product_upsert` 已被确认），否则 select / PUT 回 404。
public enum ImageGate: Equatable, Sendable {
    /// 能发：本机有这个商品（没归档），本店 outbox 里没有它还没拿到结果的登记
    case ready
    /// 先等：它的 `product_upsert` 还没传上去（或在等家用确认）
    case waiting
    /// 不用发了：本机没有这个商品、已归档，或它的登记被服务器拒了
    case gone
}

extension LocalDB {
    /// 这个商品的选图 / 照片现在能不能发（只读；不在主线程调）。只看当前会话的店：登记是这个会话写的，暂存也跟着会话走。
    /// 不用「有 applied 行」判断：确认 14 天后 outbox 行会删、收银员会话下旧 op 拿到结果就删，没有行也可能早已确认
    public func imageGate(productId: UUID) throws -> ImageGate {
        try writer.read { db in
            guard let s = try Self.currentSession(db) else { return .gone }
            let archived = try Bool.fetchOne(db, sql: "SELECT archived FROM product WHERE id = ?", arguments: [productId.uuidString])
            guard archived == false else { return .gone }
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, op_json FROM outbox WHERE store_id = ? AND type = 'product_upsert' AND status <> 'applied'
                """, arguments: [s.storeId.uuidString])
            var waiting = false
            for r in rows where Self.payloadProductIds(r["op_json"]).contains(productId) {
                let status: String = r["status"]
                if status == OutboxItem.Status.rejected.rawValue { return .gone }
                waiting = true
            }
            return waiting ? .waiting : .ready
        }
    }
}
