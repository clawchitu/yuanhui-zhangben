import Foundation

/// op 类型（§4.3）。原始值就是 JSON 里的 `type`。
public enum OpType: String, Hashable, Sendable, CaseIterable {
    case saleBatch = "sale_batch"
    case void
    case productUpsert = "product_upsert"
    case productEdit = "product_edit"
    case barcodeLink = "barcode_link"
    case barcodeUnlink = "barcode_unlink"
    case stockIn = "stock_in"
    case opening
    case productReviewComplete = "product_review_complete"
    case count
    case expiryDispose = "expiry_dispose"
    case lotSnooze = "lot_snooze"

    /// 只能联网提交、不进离线队列（§5.6 第 1 条）。`opening` 是否需要联网取决于商品新旧，由调用方判断。
    public var onlineOnly: Bool { self == .count || self == .productReviewComplete }
}

/// 一条待传的 op（`POST /v1/sync` 的 `ops[]` 一项）。
public struct Op: Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let payload: any OpPayload

    public init(id: UUID = UUID(), occurredAt: Date = Date(), payload: any OpPayload) {
        self.id = id; self.occurredAt = occurredAt; self.payload = payload
    }

    public var type: OpType { Swift.type(of: payload).opType }

    /// `occurred_at`：RFC 3339，上海时区偏移，精确到毫秒，例如 `2026-11-19T10:15:00.000+08:00`。
    public static func formatTimestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("id", id)
        b.put("type", type.rawValue)
        b.put("occurred_at", Op.formatTimestamp(occurredAt))
        b.put("payload", payload.json)
        return b.value
    }

    /// 编码后的字节（确定性输出）
    public func encoded() -> Data { json.data() }
}
