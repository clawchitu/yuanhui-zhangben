import Foundation
import GRDB
import XCTest
@testable import ShopCore

/// S22b：被踢、恢复队列（旧令牌、旧店）、退出登录推迟注销、换角色、换店、换 epoch、演示店重置、被拒不重试、每次同步补压缩。
final class SyncIdentityTests: XCTestCase, @unchecked Sendable {
    let epochA = uuid(0xEA), epochB = uuid(0xEB)
    let storeA = uuid(0x5A), storeB = uuid(0x5B)

    func session(_ role: Role, device: Int, store: UUID, token: String) throws -> LocalSession {
        try LocalSession(deviceId: uuid(device), storeId: store, role: role, tokenRef: token, storeName: "店", deviceLabel: "手机\(device)")
    }

    func makeDB(_ role: Role = .family, path: String? = nil) throws -> LocalDB {
        let db: LocalDB
        if let path { db = try LocalDB(path: path) } else {
            db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: nil)
        }
        try db.beginSession(try session(role, device: 1, store: storeA, token: "tA"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epochA.uuidString.lowercased())
        return db
    }

    @discardableResult
    func sell(_ db: LocalDB, opId: UUID = UUID()) throws -> UUID {
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b, opId: opId, at: Date())
        return opId
    }

    func body(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
    func opIds(_ d: Data) -> [String] { (body(d)["ops"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }

    /// 假服务器响应：`status(opId)` 给每个推上来的 op 一个结果
    func response(_ req: Data, epoch: UUID, revoked: Bool = false, discard: Bool = false, role: String = "family",
                  cursor: Int = 5, status: (String) -> (String, String?) = { _ in ("applied", nil) }) throws -> Data {
        let results = opIds(req).map { id -> [String: Any] in
            let (s, c) = status(id); var r: [String: Any] = ["id": id, "status": s]; if let c { r["code"] = c }; return r
        }
        var device: [String: Any] = ["role": role, "label": "手机", "revoked": revoked]
        if discard { device["discard_outbox"] = true }
        let obj: [String: Any] = [
            "results": discard ? [] : results,
            "changes": ["products": [], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": cursor, "ledger": cursor], "has_more": ["catalog": false, "ledger": false],
            "total_products": 0, "server_time": "2026-11-23T10:00:00.000Z", "epoch": epoch.uuidString.lowercased(), "min_build": 0,
            "device": device, "store": ["name": "店"]]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - 被踢

    /// 被踢的家用手机下一次同步：这批的结果照记（卖出 applied、进货 held），会话退役、投影清空，原因记成 kicked_family（25b）
    func testKickedFamilyRecordsResultsAndRetires() throws {
        let db = try makeDB()
        let sale = try sell(db)
        let pid = DemoSeed.id(0x201)
        let stockIn = UUID()
        try db.recordStockIn(try StockInPayload(entryId: UUID(), productId: pid, barcode: "6901035600016", packQty: 1, packCount: 2,
                                                unitCostFen: Fen(300)), name: "x", unitName: "瓶", opId: stockIn)
        let engine = SyncEngine(db: db, appBuild: 1) { req in
            (200, try self.response(req, epoch: self.epochA, revoked: true) { id in
                id == stockIn.uuidString.lowercased() ? ("held", nil) : ("applied", nil) })
        }
        XCTAssertThrowsError(try engine.sync()) { XCTAssertEqual($0 as? SyncError, .revoked(discardOutbox: false)) }
        XCTAssertNil(try db.currentSession())
        XCTAssertEqual(try db.signOutReason(), .kickedFamily)
        let out = Dictionary(uniqueKeysWithValues: try db.allOutbox().map { ($0.id, $0.status) })
        XCTAssertEqual(out[sale], .applied)
        XCTAssertEqual(out[stockIn], .held)
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
        XCTAssertEqual(try db.productCount(), 0, "投影清空")
        XCTAssertEqual(try db.retiredSession(deviceId: uuid(1))?.revoked, true)
        XCTAssertEqual(try db.retiredSession(deviceId: uuid(1))?.epoch, epochA, "退役时存下旧会话的 epoch")
    }

    func testKickedCashierReasonIs25f() throws {
        let db = try makeDB(.cashier)
        try sell(db)
        let engine = SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA, revoked: true, role: "cashier")) }
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try db.signOutReason(), .kickedCashier)
    }

    // MARK: - 恢复队列

    /// 断网退出登录：未传的进恢复队列（logout 推迟）。换扫收银员码后：用**旧令牌**、旧 epoch、pull:false 传；结果按**旧店**记；
    /// 收银员会话下拿到结果就删；传完才用旧令牌调 logout，然后删旧令牌、删会话行
    func testOfflineLogoutThenCashierUploadsWithOldTokenThenLogsOut() throws {
        let db = try makeDB()
        let a = try sell(db), b = try sell(db)
        try db.endSession(logoutPending: true)
        XCTAssertEqual(try db.recoveryPendingCount(), 2, "提示「还有 2 笔没传」")
        let tokens = MemoryTokenStore()
        try tokens.save("token-A", ref: "tA"); try tokens.save("token-C", ref: "tC")
        try db.beginSession(try session(.cashier, device: 2, store: storeB, token: "tC"))
        try db.setMeta(.serverEpoch, epochB.uuidString)
        XCTAssertEqual(try db.productCount(), 0, "投影清空")
        XCTAssertEqual(try db.recoveryPendingCount(), 2, "恢复队列不动")
        let calls = Box<[RecoveryCall]>([])
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            calls.value.append(call)
            switch call {
            case .sync(let t, let req):
                XCTAssertEqual(t, "token-A", "恢复队列只用旧令牌")
                XCTAssertEqual(self.body(req)["pull"] as? Bool, false)
                XCTAssertEqual(self.body(req)["epoch"] as? String, self.epochA.uuidString.lowercased())
                return (200, try self.response(req, epoch: self.epochA))
            case .logout(let t):
                XCTAssertEqual(t, "token-A")
                return (204, Data())
            }
        }
        let r = try up.run()
        XCTAssertEqual(r.resolved, 2); XCTAssertEqual(r.remaining, 0); XCTAssertEqual(r.finished, [uuid(1)])
        guard case .sync(_, let sent) = calls.value.first, case .logout = calls.value.last else { return XCTFail("先传、后 logout") }
        XCTAssertEqual(Set(opIds(sent)), Set([a, b].map { $0.uuidString.lowercased() }))
        XCTAssertTrue(try db.allOutbox().isEmpty, "收银员会话下旧会话的 op 拿到结果就删")
        XCTAssertNil(try tokens.token(ref: "tA"), "传完才删旧令牌")
        XCTAssertNotNil(try tokens.token(ref: "tC"))
        XCTAssertNil(try db.retiredSession(deviceId: uuid(1)))
    }

    /// 没网：恢复队列传不上去不拦，旧令牌留着、logout 不调
    func testRecoveryOfflineKeepsTokenAndOps() throws {
        let db = try makeDB()
        try sell(db)
        try db.endSession(logoutPending: true)
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertThrowsError(try up.run())
        XCTAssertEqual(try db.recoveryPendingCount(), 1)
        XCTAssertEqual(try tokens.token(ref: "tA"), "token-A")
    }

    /// op id 只在店内唯一：恢复队列的结果只记到旧店那一条，当前店同 id 的 op 不受影响（§8 S22b 约束）
    func testRecoveryResultsUseOldSessionsStore() throws {
        let db = try makeDB()
        let shared = UUID()
        try sell(db, opId: shared)
        try db.endSession()
        try db.beginSession(try session(.family, device: 2, store: storeB, token: "tB"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, epochB.uuidString)
        try sell(db, opId: shared)
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            guard case .sync(_, let req) = call else { return (204, Data()) }
            return (200, try self.response(req, epoch: self.epochA) { _ in ("rejected", "forbidden") })
        }
        let r = try up.run()
        XCTAssertEqual(r.rejected, 1)
        let rows = try db.allOutbox().filter { $0.id == shared }
        XCTAssertEqual(rows.first { $0.storeId == storeA }?.status, .rejected)
        XCTAssertEqual(rows.first { $0.storeId == storeB }?.status, .pending, "当前店同 id 的 op 还是待传")
        XCTAssertEqual(try db.pendingOps().map(\.id), [shared], "当前会话照常推它")
    }

    /// 收银员会话下旧会话被拒的 op 已删、读不回；首页提示的数来自当次响应，「知道了」后清零
    func testCashierRecoveryRejectionsCountedFromResponse() throws {
        let db = try makeDB()
        try sell(db); try sell(db)
        try db.endSession()
        try db.beginSession(try session(.cashier, device: 2, store: storeB, token: "tC"))
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let first = Box(true)
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            guard case .sync(_, let req) = call else { return (204, Data()) }
            return (200, try self.response(req, epoch: self.epochA) { _ in
                defer { first.value = false }; return first.value ? ("rejected", "forbidden") : ("held", nil) })
        }
        let r = try up.run()
        XCTAssertEqual(r.rejected, 1); XCTAssertEqual(r.held, 1)
        XCTAssertTrue(try db.allOutbox().isEmpty, "被拒、held 的一样拿到结果就删")
        XCTAssertEqual(try db.rejectedUnseenCount(), 1)
        try db.acknowledgeRejected()
        XCTAssertEqual(try db.rejectedUnseenCount(), 0)
    }

    /// 旧会话那家店换了 epoch：409 带回新 epoch，记下再发
    func testRecoveryEpochHandshake() throws {
        let db = try makeDB()
        try sell(db)
        try db.endSession(revoked: true)
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let epochs = Box<[String]>([])
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            guard case .sync(_, let req) = call else { XCTFail("被踢的不调 logout"); return (204, Data()) }
            let e = self.body(req)["epoch"] as! String
            epochs.value.append(e)
            if e != self.epochB.uuidString.lowercased() {
                return (409, try JSONSerialization.data(withJSONObject: ["code": "epoch_mismatch", "epoch": self.epochB.uuidString.lowercased()]))
            }
            return (200, try self.response(req, epoch: self.epochB, revoked: true))
        }
        XCTAssertEqual(try up.run().remaining, 0)
        XCTAssertEqual(epochs.value, [epochA, epochB].map { $0.uuidString.lowercased() })
    }

    /// 换登另一家店：原店未传的 op 只用原店的旧令牌发，当前店（演示店）的同步请求里一条都没有
    func testSwitchStoreNeverSendsOldOpsWithNewToken() throws {
        let db = try makeDB()
        let old = try sell(db)
        try db.endSession(logoutPending: true)
        try db.beginSession(try session(.family, device: 3, store: storeB, token: "tDemo"))
        try db.setMeta(.serverEpoch, epochB.uuidString)
        XCTAssertNil(try db.nextPushBatch(), "当前会话（演示店）没有要推的")
        let engine = SyncEngine(db: db, appBuild: 1) { req in
            XCTAssertFalse(self.opIds(req).contains(old.uuidString.lowercased()), "原店的 op 不进演示店")
            return (200, try self.response(req, epoch: self.epochB))
        }
        try engine.sync()
        XCTAssertEqual(try db.recoveryQueue().map(\.tokenRef), ["tA"])
    }

    // MARK: - 演示店重置

    func testDemoResetDiscardsOutboxWithoutReplay() throws {
        let db = try makeDB()
        try sell(db); try sell(db)
        let engine = SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA, revoked: true, discard: true)) }
        XCTAssertThrowsError(try engine.sync()) { XCTAssertEqual($0 as? SyncError, .revoked(discardOutbox: true)) }
        XCTAssertTrue(try db.allOutbox().isEmpty, "丢弃，不重放")
        XCTAssertEqual(try db.signOutReason(), .demoReset)
        XCTAssertNil(try db.retiredSession(deviceId: uuid(1)))
    }

    // MARK: - 换 epoch

    /// 服务器换 epoch：握手 → 投影和游标清掉、保留的已确认 op 重新标成待传 → 再发（同 id，服务器幂等）→ 正常同步
    func testEpochMismatchRebuildsAndResendsRetainedOps() throws {
        let db = try makeDB()
        let a = try sell(db)
        let round = Box(0), sent = Box<[[String]]>([]), cursors = Box<[Int]>([])
        let serverEpoch = Box(epochA)
        let engine = SyncEngine(db: db, appBuild: 1) { req in
            round.value += 1
            sent.value.append(self.opIds(req))
            cursors.value.append(((self.body(req)["cursors"] as? [String: Any])?["catalog"] as? Int) ?? -1)
            if (self.body(req)["epoch"] as? String) != serverEpoch.value.uuidString.lowercased() {
                return (409, try JSONSerialization.data(withJSONObject: ["code": "epoch_mismatch", "epoch": serverEpoch.value.uuidString.lowercased()]))
            }
            return (200, try self.response(req, epoch: serverEpoch.value, cursor: 7))
        }
        try engine.sync()
        XCTAssertEqual(try db.allOutbox().first?.status, .applied)
        serverEpoch.value = epochB     // 运维从备份恢复后换 epoch
        sent.value = []; cursors.value = []
        try engine.sync()
        XCTAssertEqual(sent.value.first, [], "旧 epoch 的请求里没有新 op")
        XCTAssertEqual(sent.value.dropFirst().first, [a.uuidString.lowercased()], "握手后重发保留的 op")
        XCTAssertEqual(cursors.value.dropFirst().first, 0, "游标归零，全量拉取")
        XCTAssertEqual(try db.meta(.serverEpoch)?.lowercased(), epochB.uuidString.lowercased())
        XCTAssertEqual(try db.allOutbox().map(\.status), [.applied])
    }

    /// 被拒的不重发（换 epoch 也不），首页提示，「知道了」清零
    func testRejectedNotRetriedAndPrompted() throws {
        let db = try makeDB()
        try sell(db)
        let sent = Box<[[String]]>([])
        let engine = SyncEngine(db: db, appBuild: 1) { req in
            sent.value.append(self.opIds(req))
            return (200, try self.response(req, epoch: self.epochA) { _ in ("rejected", "forbidden") })
        }
        try engine.sync()
        try engine.sync()
        XCTAssertEqual(sent.value.map(\.count), [1, 0], "第二趟不再发")
        XCTAssertEqual(try db.rejectedUnseenCount(), 1)
        try db.resetForEpoch(epochB)
        XCTAssertNil(try db.nextPushBatch(), "换 epoch 也不重发被拒的")
        try db.acknowledgeRejected()
        XCTAssertEqual(try db.rejectedUnseenCount(), 0)
    }

    // MARK: - 每次同步补压缩

    func testSyncCompactsAndRetriesNextTimeWhenBusy() throws {
        let path = NSTemporaryDirectory() + "yh-s22b-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let db = try makeDB(path: path)
        let pool = try XCTUnwrap(db.writer as? DatabasePool)
        try db.writer.write { try LocalDB.markCompactionPending($0) }
        var snapshot: DatabaseSnapshot? = try pool.makeSnapshot()
        XCTAssertNotNil(snapshot)
        let engine = SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }
        try engine.sync()   // 被读事务挡住：同步照常，标记留着
        XCTAssertTrue(try db.needsCompaction())
        snapshot = nil
        try engine.sync()   // 下次同步补做
        XCTAssertFalse(try db.needsCompaction())
    }

    // MARK: - PR #41 必须修 2：换 epoch 要覆盖退役会话保留的 op

    /// 旧会话（同一家店）传完、logout 也调了：令牌留到保留的 op 清掉；当前会话握手换 epoch 时，旧会话保留的 op 一起重标，
    /// 由恢复队列用**旧令牌**重传
    func testEpochResetCoversRetiredSessionOfSameStore() throws {
        let db = try makeDB()
        let old = try sell(db)
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA"); try tokens.save("token-B", ref: "tB")
        try SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }.sync()
        try db.endSession(logoutPending: true)
        let logouts = Box(0)
        let sent = Box<[(String, [String])]>([])
        let serverB = Box(false)
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            switch call {
            case .logout: logouts.value += 1; return (204, Data())
            case .sync(let t, let req):
                // 服务器现在的 epoch：换之前是 A，换之后是 B；带的不一样就 409
                let e = self.body(req)["epoch"] as? String
                let current = (serverB.value ? self.epochB : self.epochA).uuidString.lowercased()
                if e == current {
                    sent.value.append((t, self.opIds(req)))
                    return (200, try self.response(req, epoch: serverB.value ? self.epochB : self.epochA))
                }
                return (409, try JSONSerialization.data(withJSONObject: ["code": "epoch_mismatch", "epoch": self.epochB.uuidString.lowercased()]))
            }
        }
        try up.run()
        XCTAssertEqual(logouts.value, 1, "传完调 logout")
        XCTAssertEqual(try tokens.token(ref: "tA"), "token-A", "保留期内的 op 还在：旧令牌留着（换 epoch 要用）")
        // 新会话，同一家店（epoch 相同）
        try db.beginSession(try session(.family, device: 2, store: storeB, token: "tB"))
        try db.setMeta(.serverEpoch, epochA.uuidString)
        serverB.value = true; sent.value = []
        try db.resetForEpoch(epochB)
        XCTAssertEqual(try db.recoveryPendingCount(), 0, "握手本身不重标旧会话（只探有令牌的）")
        try up.run(probeEpochs: true)   // 握手后当趟探测（App 里由协调器触发）
        XCTAssertEqual(sent.value.map(\.0), ["token-A"], "用旧会话自己的令牌")
        XCTAssertEqual(sent.value.first?.1, [old.uuidString.lowercased()])
        XCTAssertEqual(logouts.value, 2, "重传完再注销一次")
        XCTAssertEqual(try db.retiredSession(deviceId: uuid(1))?.epoch, epochB)
    }

    /// 旧会话是别的店（epoch 不同）：启动时探一下它那家店，409 → 保留的 op 重标、用旧令牌重传
    func testProbeFindsRetiredStoreEpochChange() throws {
        let db = try makeDB()
        let old = try sell(db)
        try SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }.sync()
        try db.endSession(revoked: true)
        try db.beginSession(try session(.family, device: 2, store: storeB, token: "tB"))
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let serverEpoch = Box(epochA), sent = Box<[[String]]>([])
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            guard case .sync(_, let req) = call else { return (204, Data()) }
            if (self.body(req)["epoch"] as? String) != serverEpoch.value.uuidString.lowercased() {
                return (409, try JSONSerialization.data(withJSONObject: ["code": "epoch_mismatch", "epoch": serverEpoch.value.uuidString.lowercased()]))
            }
            sent.value.append(self.opIds(req))
            return (200, try self.response(req, epoch: serverEpoch.value, revoked: true))
        }
        serverEpoch.value = epochB   // 旧会话那家店从备份恢复、换了 epoch
        try up.run()
        XCTAssertEqual(sent.value, [], "不探就不知道")
        try up.run(probeEpochs: true)
        XCTAssertEqual(sent.value.last, [old.uuidString.lowercased()], "保留的 op 用旧令牌重传")
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
    }

    /// 旧令牌在保留的 op 过了 14 天清掉之后才删
    func testRetiredTokenDeletedAfterRetentionPurge() throws {
        let db = try makeDB()
        try sell(db)
        try SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }.sync()
        try db.endSession(revoked: true)
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA")
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { _ in (204, Data()) }
        try up.run()
        XCTAssertNotNil(try tokens.token(ref: "tA"))
        try db.purgeConfirmed(now: Date().addingTimeInterval(15 * 86_400))
        try up.run()
        XCTAssertNil(try tokens.token(ref: "tA"))
        XCTAssertNil(try db.retiredSession(deviceId: uuid(1)))
    }

    /// 探测遇到 5xx：这趟不算探过（App 里下趟再探）；钥匙串里没有令牌的会话不探、不重标
    func testProbeIncompleteOn5xxAndSkipsSessionsWithoutToken() throws {
        let db = try makeDB()
        try sell(db)
        try SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }.sync()
        try db.endSession(revoked: true)
        let tokens = MemoryTokenStore()
        let calls = Box(0)
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { _ in calls.value += 1; return (503, Data()) }
        XCTAssertFalse(try up.run(probeEpochs: true).probeIncomplete, "没有令牌：不探")
        XCTAssertEqual(calls.value, 0)
        try tokens.save("token-A", ref: "tA")
        XCTAssertTrue(try up.run(probeEpochs: true).probeIncomplete)
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
    }

    /// 探测遇到演示店重置：这家店的 op 丢掉，同店所有退役会话的令牌都删，不留孤立令牌
    func testProbeDiscardDeletesAllTokensOfStore() throws {
        let db = try makeDB()
        try sell(db)
        try SyncEngine(db: db, appBuild: 1) { req in (200, try self.response(req, epoch: self.epochA)) }.sync()
        try db.endSession(revoked: true)
        // 同一家店（本机店 id 相同）的另一个退役会话
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO session (device_id, store_id, role, token_ref, store_name, device_label, is_current, created_at, retired_at)
                VALUES (?, ?, 'family', 'tA2', '店', '手机', 0, '2026-11-20T00:00:00.000+08:00', '2026-11-21T00:00:00.000+08:00')
                """, arguments: [uuid(9).uuidString, storeA.uuidString])
        }
        let tokens = MemoryTokenStore(); try tokens.save("token-A", ref: "tA"); try tokens.save("token-A2", ref: "tA2")
        let up = RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            guard case .sync(_, let req) = call else { return (204, Data()) }
            return (200, try self.response(req, epoch: self.epochA, revoked: true, discard: true))
        }
        let r = try up.run(probeEpochs: true)
        XCTAssertTrue(r.discarded)
        XCTAssertTrue(try db.allOutbox().isEmpty)
        XCTAssertNil(try tokens.token(ref: "tA"))
        XCTAssertNil(try tokens.token(ref: "tA2"), "同店的孤立令牌也删")
    }
}
