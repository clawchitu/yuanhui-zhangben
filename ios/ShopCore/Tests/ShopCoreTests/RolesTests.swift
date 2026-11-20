import XCTest
@testable import ShopCore

final class RolesTests: XCTestCase {
    /// 生成的权限表与 contracts/permissions.json 逐格一致（改了 json 没重跑生成脚本时这里失败）
    func testGeneratedTableMatchesPermissionsJSON() throws {
        let root = try loadJSON("contracts/permissions.json") as! [String: Any]
        XCTAssertEqual(int64(root["version"]).map(Int.init), PermissionTable.version)
        let rules = root["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.map { $0["id"] as! String }, PermissionTable.rules.map(\.id), "行和顺序一致")
        for r in rules {
            let id = r["id"] as! String
            let gen = try XCTUnwrap(PermissionTable.rule(id))
            XCTAssertEqual(gen.kind, r["kind"] as! String, id)
            for role in Role.allCases {
                let cell = r[role.rawValue] as! [String: Any]
                XCTAssertEqual(gen.cell(role).decision.rawValue, cell["decision"] as! String, "\(id) \(role)")
                XCTAssertEqual(gen.cell(role).conditions, (cell["conditions"] as? [String]) ?? [], "\(id) \(role)")
            }
        }
    }

    /// 能力表依赖的每一行都真实存在于权限表（防止拼错 id 被当成「不给」静默吞掉）
    func testEveryCapabilityRuleExists() {
        for cap in Capability.allCases {
            for id in cap.ruleIds { XCTAssertNotNil(PermissionTable.rule(id), "\(cap) → \(id)") }
        }
        for t in OpType.allCases where t != .productUpsert {
            XCTAssertNotNil(PermissionTable.rule("op:\(t.rawValue)"), t.rawValue)
        }
    }

    /// 验收：收银员没有进货、看账、商品等能力
    func testCashierCapabilities() {
        let c = Capabilities(role: .cashier)
        XCTAssertEqual(c.granted, [.sell, .void, .quickRegister, .barcodeLookup])
        for cap: Capability in [.stockIn, .viewReports, .manageProducts, .fullRegister, .opening, .reviewComplete,
                                .count, .expiry, .pairing, .manageDevices, .renameDevice, .account, .heldOps] {
            XCTAssertFalse(c.has(cap), "收银员不该有 \(cap)")
        }
        // 撤销带条件：本机、当天（§6 原则 ③）
        XCTAssertEqual(c.conditions[.void], ["own_device_sale", "sale_day_eq_server_receive_day"])
        XCTAssertTrue(c.canSend(.saleBatch))
        XCTAssertTrue(c.canSend(.productUpsert, quick: true))
        XCTAssertFalse(c.canSend(.productUpsert, quick: false))
        XCTAssertFalse(c.canSend(.stockIn))
        XCTAssertFalse(c.canSend(.count))
    }

    func testFamilyAndReviewHaveEverything() {
        for role: Role in [.family, .review] {
            let c = Capabilities(role: role)
            XCTAssertEqual(c.granted, Set(Capability.allCases), "\(role)")
            XCTAssertTrue(c.conditions[.void] == nil, "\(role) 撤销不带条件")
            for t in OpType.allCases { XCTAssertTrue(c.canSend(t, quick: false), "\(role) \(t)") }
        }
        XCTAssertEqual(Capabilities(role: .family).conditions[.manageDevices], ["not_self"])
    }

    func testRevokedHasNoInteractiveCapability() {
        let c = Capabilities(role: .revoked)
        // 被踢设备只在恢复队列里补传卖出和临时登记（有条件），界面上什么都不给
        XCTAssertEqual(c.granted, [.sell, .quickRegister])
        XCTAssertEqual(c.conditions[.sell], ["occurred_at_lte_revoked_at", "within_revoke_window"])
    }
}
