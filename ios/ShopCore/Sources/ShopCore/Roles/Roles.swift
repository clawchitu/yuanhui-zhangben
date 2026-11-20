/// 身份（§6）。`revoked` 是被踢设备，客户端只在恢复队列里用到。
public enum Role: String, Hashable, Sendable, CaseIterable, Codable {
    case family, cashier, review, revoked
}

/// `permissions.json` 的 `decision`
public enum PermissionDecision: String, Hashable, Sendable {
    case `public`, allow, deny, held
    case notApplicable = "not_applicable"
}

public struct PermissionCell: Hashable, Sendable {
    public let decision: PermissionDecision
    /// 有条件时全部满足才能（例如收银员撤销：本机、当天）
    public let conditions: [String]
    /// 数据范围（`permissions.json` 的 `scope`，例如 `sync:pull` 的 `full_store` / `cashier_projection`）
    public let scope: String?
    public init(_ decision: PermissionDecision, conditions: [String] = [], scope: String? = nil) {
        self.decision = decision; self.conditions = conditions; self.scope = scope
    }
    /// 这个身份能不能做（不论有没有附加条件）
    public var permits: Bool { decision == .allow || decision == .public }
}

public struct PermissionRule: Hashable, Sendable {
    public let id: String
    public let kind: String
    public let cells: [Role: PermissionCell]
    public init(id: String, kind: String, cells: [Role: PermissionCell]) {
        self.id = id; self.kind = kind; self.cells = cells
    }
    public func cell(_ role: Role) -> PermissionCell { cells[role] ?? PermissionCell(.deny) }
}

/// 权限表（§6.1），由 `scripts/gen-permissions.py` 从 `contracts/permissions.json` 生成。
/// 界面隐藏只是体验，真正的权限在服务器上判（§6 原则 ①）。
public enum PermissionTable {
    public static func rule(_ id: String) -> PermissionRule? { rules.first { $0.id == id } }
}

/// 界面上的能力（决定有哪些入口）。每项能力对应权限表里的若干行，**这些行全都允许**才算有这项能力。
public enum Capability: String, Hashable, Sendable, CaseIterable {
    case sell              // 卖出（含抹零）
    case void              // 撤销（收银员有条件：本机当天）
    case quickRegister     // 临时登记新商品（04c）
    case fullRegister      // 完整登记（04a/04b）
    case stockIn           // 进货
    case opening           // 期初库存
    case reviewComplete    // 待确认补全（22b）
    case count             // 盘点
    case expiry            // 处理快过期
    case viewReports       // 看账（09/10、记的账全店）
    case manageProducts    // 商品管理（改商品、整件码）
    case barcodeLookup     // 查条码名称
    case pairing           // 给家人 / 收银员开通
    case manageDevices     // 已登录的手机
    case renameDevice      // 改手机名
    case account           // 账号与密码、注销
    case heldOps           // 处理被踢设备暂存的账

    /// 这项能力依赖的权限表行 id
    public var ruleIds: [String] {
        switch self {
        case .sell: return ["op:sale_batch"]
        case .void: return ["op:void"]
        case .quickRegister: return ["op:product_upsert[quick]"]
        case .fullRegister: return ["op:product_upsert[full]"]
        case .stockIn: return ["op:stock_in"]
        case .opening: return ["op:opening"]
        case .reviewComplete: return ["op:product_review_complete"]
        case .count: return ["op:count"]
        case .expiry: return ["op:expiry_dispose", "op:lot_snooze"]
        case .viewReports: return ["GET /v1/reports/today", "GET /v1/reports/month", "GET /v1/entries", "GET /v1/entries/days"]
        case .manageProducts: return ["op:product_edit", "op:barcode_link", "op:barcode_unlink"]
        case .barcodeLookup: return ["GET /v1/barcode-lookup/{barcode}"]
        case .pairing: return ["POST /v1/pairing-tokens", "GET /v1/pairing-tokens/{id}"]
        case .manageDevices: return ["GET /v1/devices", "POST /v1/devices/{id}/revoke", "POST /v1/devices/revoke-others"]
        case .renameDevice: return ["PATCH /v1/devices/me"]
        case .account: return ["POST /v1/account/password", "POST /v1/account/delete-request", "POST /v1/account/delete-cancel"]
        case .heldOps: return ["GET /v1/held-ops", "POST /v1/held-ops/{id}/resolve"]
        }
    }
}

/// 某个身份的能力表，从权限表算出来。
public struct Capabilities: Hashable, Sendable {
    public let role: Role
    public let granted: Set<Capability>
    /// 有能力但带附加条件的（例如收银员撤销），值是条件名
    public let conditions: [Capability: [String]]

    public init(role: Role) {
        self.role = role
        var g = Set<Capability>()
        var conds: [Capability: [String]] = [:]
        for cap in Capability.allCases {
            let cells = cap.ruleIds.map { id -> PermissionCell in
                guard let r = PermissionTable.rule(id) else { return PermissionCell(.deny) }  // 表里没有 = 不给
                return r.cell(role)
            }
            if cells.allSatisfy(\.permits) {
                g.insert(cap)
                let c = cells.flatMap(\.conditions)
                if !c.isEmpty { conds[cap] = c }
            }
        }
        granted = g
        conditions = conds
    }

    public func has(_ c: Capability) -> Bool { granted.contains(c) }

    /// 本机能发出的 op（家用 / 审核全部；收银员只有卖出、撤销、临时登记）
    public func canSend(_ type: OpType, quick: Bool = false) -> Bool {
        let id = type == .productUpsert ? "op:product_upsert[\(quick ? "quick" : "full")]" : "op:\(type.rawValue)"
        return PermissionTable.rule(id)?.cell(role).permits ?? false
    }
}

/// `sync:pull` 给这个身份下发的数据范围（§4.2、§6.1）。
public enum PullScope: String, Hashable, Sendable {
    /// 全店（家用、审核）
    case fullStore = "full_store"
    /// 收银员裁剪版：没有库存、货值、进价、批次
    case cashierProjection = "cashier_projection"

    /// 从权限表的 `sync:pull` 行推出；拉不了（被踢）或表里没有时为 nil
    public static func of(_ role: Role) -> PullScope? {
        guard let cell = PermissionTable.rule("sync:pull")?.cell(role), cell.permits else { return nil }
        return cell.scope.flatMap(PullScope.init(rawValue:))
    }
}

/// 库存、货值、进价在这台手机上看不看得见（§14 S12-3）。
/// 权限表里没有单独的一行：由 `sync:pull` 的 `scope` 推出——服务器不下发的东西，界面上也不显示。
/// 不借用「进货」能力判断：能不能进货和能不能看库存是两回事。
public enum DataVisibility {
    /// 能看库存数（「还剩 126 罐」、快没货、快过期）
    public static func seesStock(_ role: Role) -> Bool { PullScope.of(role) == .fullStore }
    /// 能看进价、货值、平均进价
    public static func seesCost(_ role: Role) -> Bool { PullScope.of(role) == .fullStore }
}
