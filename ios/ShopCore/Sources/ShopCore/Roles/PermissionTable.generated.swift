// 自动生成，勿手改。来源：contracts/permissions.json（version 1）。
// 生成：python3 ios/ShopCore/scripts/gen-permissions.py

extension PermissionTable {
    public static let version = 1
    public static let rules: [PermissionRule] = [
        PermissionRule(id: "GET /healthz", kind: "http", cells: [
            .family: PermissionCell(.public, conditions: []),
            .cashier: PermissionCell(.public, conditions: []),
            .review: PermissionCell(.public, conditions: []),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/config", kind: "http", cells: [
            .family: PermissionCell(.public, conditions: []),
            .cashier: PermissionCell(.public, conditions: []),
            .review: PermissionCell(.public, conditions: []),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/auth/login", kind: "http", cells: [
            .family: PermissionCell(.public, conditions: []),
            .cashier: PermissionCell(.public, conditions: []),
            .review: PermissionCell(.public, conditions: []),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/auth/pair/redeem", kind: "http", cells: [
            .family: PermissionCell(.public, conditions: []),
            .cashier: PermissionCell(.public, conditions: []),
            .review: PermissionCell(.public, conditions: []),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/auth/demo", kind: "http", cells: [
            .family: PermissionCell(.public, conditions: ["demo_login_enabled"]),
            .cashier: PermissionCell(.public, conditions: ["demo_login_enabled"]),
            .review: PermissionCell(.public, conditions: ["demo_login_enabled"]),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/auth/logout", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.notApplicable, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/me", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/sync", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.allow, conditions: [])
        ]),
        PermissionRule(id: "sync:pull", kind: "sync_pull", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/barcode-lookup/{barcode}", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/images/{product_id}", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/reports/today", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/reports/month", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/entries", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/entries/days", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/pairing-tokens", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/pairing-tokens/{id}", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/devices", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/devices/{id}/revoke", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: ["not_self"]),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: ["not_self"]),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/devices/revoke-others", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "PATCH /v1/devices/me", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "GET /v1/held-ops", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/held-ops/{id}/resolve", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/recovery/import", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: ["recovery_mode_on"]),
            .cashier: PermissionCell(.allow, conditions: ["recovery_mode_on"]),
            .review: PermissionCell(.deny, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/account/password", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/account/delete-request", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "POST /v1/account/delete-cancel", kind: "http", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.deny, conditions: [])
        ]),
        PermissionRule(id: "op:sale_batch", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.allow, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:void", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: ["own_device_sale", "sale_day_eq_server_receive_day"]),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:product_upsert[quick]", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.allow, conditions: ["quick_only"]),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.allow, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:product_upsert[full]", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:product_edit", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:barcode_link", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:barcode_unlink", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:stock_in", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:opening", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:product_review_complete", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:count", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:expiry_dispose", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
        PermissionRule(id: "op:lot_snooze", kind: "op", cells: [
            .family: PermissionCell(.allow, conditions: []),
            .cashier: PermissionCell(.deny, conditions: []),
            .review: PermissionCell(.allow, conditions: []),
            .revoked: PermissionCell(.held, conditions: ["occurred_at_lte_revoked_at", "within_revoke_window"])
        ]),
    ]
}
