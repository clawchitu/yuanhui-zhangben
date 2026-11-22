import Foundation
import Testing
@testable import ShopCore

/// S21 服务器地址白名单（plan-v2 §8 S21；PR #33 Fable 交接 1–5）。主机只在测试里写，ShopCore 源码里没有主机字面量。
@Suite struct APIBaseTests {
    static let ip = "47.117.184.253"
    static let domain = "api.yuanhuishop.cn"
    let beta = APIBasePolicy(hosts: [ip, domain])
    let release = APIBasePolicy(hosts: [domain])
    let debug = APIBasePolicy(hosts: [ip, domain], allowLoopbackHTTP: true)

    @Test func planRejectExamples() {
        for s in ["https://evil.example", "https://api.yuanhuishop.cn.evil.example", "https://api.yuanhuishop.cn@evil.example",
                  "https://evil.api.yuanhuishop.cn", "https://evil.example@api.yuanhuishop.cn"] {
            #expect(APIBase.accept(s, policy: debug) == nil, "\(s)")
        }
        // 主机对、只靠「没有用户信息」那一条拒掉
        #expect(URLComponents(string: "https://evil.example@api.yuanhuishop.cn")?.host == Self.domain)
    }

    @Test func boundaryRejects() {
        for s in ["http://api.yuanhuishop.cn", "HTTPS://api.yuanhuishop.cn", "https://API.yuanhuishop.cn", "https://api.yuanhuishop.cn.",
                  "https://api.yuanhuishop.cn:8443", "https://api.yuanhuishop.cn:0443/x", "https://api.yuanhuishop.cn/x",
                  "https://api.yuanhuishop.cn/?a=1", "https://api.yuanhuishop.cn/#f", "https://user:pw@api.yuanhuishop.cn",
                  "https://api.yuanhuishop.cn\n", " https://api.yuanhuishop.cn", "https://api.yuanhuishop.cn//", "https://api%2Eyuanhuishop.cn",
                  "https://47.117.184.253:444", "api.yuanhuishop.cn", "", "https://", "https://:443",
                  // 回环地址只在 Debug 策略放行，且只认 http + 两个主机
                  "http://localhost:8787", "http://127.0.0.1:9", "https://localhost"] {
            #expect(APIBase.accept(s, policy: beta) == nil, "\(s)")
        }
        for s in ["http://localhost:8787/x", "http://user@localhost:8787", "http://localhost:8787?q", "http://0.0.0.0:8787",
                  "http://localhost.evil:8787", "ftp://localhost:21"] {
            #expect(APIBase.accept(s, policy: debug) == nil, "\(s)")
        }
    }

    @Test func fourSpellingsNormalizeToOne() {
        for s in ["https://api.yuanhuishop.cn", "https://api.yuanhuishop.cn/", "https://api.yuanhuishop.cn:443", "https://api.yuanhuishop.cn:443/"] {
            #expect(APIBase.accept(s, policy: release)?.absoluteString == "https://api.yuanhuishop.cn", "\(s)")
        }
        #expect(APIBase.accept("https://47.117.184.253/", policy: beta)?.absoluteString == "https://47.117.184.253")
        #expect(APIBase.accept("http://localhost:55123/", policy: debug)?.absoluteString == "http://localhost:55123")
        #expect(APIBase.url(URL(string: "https://api.yuanhuishop.cn/")!, path: "/v1/config").absoluteString == "https://api.yuanhuishop.cn/v1/config")
    }

    @Test func releaseRejectsIP() {
        #expect(APIBase.accept("https://47.117.184.253", policy: release) == nil)
        #expect(APIBase.accept("https://api.yuanhuishop.cn", policy: release) != nil)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "apibase-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func storedOutsideWhitelistIsDeletedAtStartup() {
        let d = freshDefaults()
        d.set("https://evil.example", forKey: APIBaseStore.storageKey)
        let logs = LogBox()
        let s = APIBaseStore(defaultBase: "https://47.117.184.253", policy: beta, defaults: d, log: { logs.add($0) })!
        #expect(s.current.absoluteString == "https://47.117.184.253")
        #expect(d.string(forKey: APIBaseStore.storageKey) == nil)
        #expect(logs.count == 1)
        // Beta 存过 IP、换成 Release 包：IP 不在 Release 白名单里，同样删掉
        d.set("https://47.117.184.253", forKey: APIBaseStore.storageKey)
        let r = APIBaseStore(defaultBase: "https://api.yuanhuishop.cn", policy: release, defaults: d)!
        #expect(r.current.absoluteString == "https://api.yuanhuishop.cn")
        #expect(d.string(forKey: APIBaseStore.storageKey) == nil)
    }

    @Test func adoptOnlyWhitelistedAndDifferent() {
        let d = freshDefaults()
        let s = APIBaseStore(defaultBase: "https://47.117.184.253", policy: beta, defaults: d)!
        #expect(s.adopt(nil) == .absent)
        for bad in ["https://evil.example", "https://evil.example@api.yuanhuishop.cn"] {
            #expect(s.adopt(bad) == .rejected)
            #expect(s.current.absoluteString == "https://47.117.184.253")
        }
        #expect(s.adopt("https://47.117.184.253:443/") == .unchanged)
        #expect(s.adopt("https://api.yuanhuishop.cn/") == .adopted(URL(string: "https://api.yuanhuishop.cn")!))
        #expect(s.adopt("https://api.yuanhuishop.cn:443") == .unchanged)
        #expect(d.string(forKey: APIBaseStore.storageKey) == "https://api.yuanhuishop.cn")
        // 重开仍用新地址
        let again = APIBaseStore(defaultBase: "https://47.117.184.253", policy: beta, defaults: d)!
        #expect(again.current.absoluteString == "https://api.yuanhuishop.cn")
        #expect(again.usingAdopted)
    }

    @Test func badDefaultRefused() {
        #expect(APIBaseStore(defaultBase: "https://47.117.184.253", policy: release, defaults: freshDefaults()) == nil)
    }

    @Test func pairingCode() {
        #expect(PairingCode.parse("YHZB1:abcDEF123") == "abcDEF123")
        for s in ["YHZB1:", "YHZB2:abc", "abc", "yhzb1:abc", "YHZB1:a b", "YHZB1:" + String(repeating: "a", count: 129)] {
            #expect(PairingCode.parse(s) == nil, "\(s)")
        }
    }

    @Test func memoryTokenStore() throws {
        let t = MemoryTokenStore()
        let ref = TokenRef.forDevice(UUID())
        try t.save("x", ref: ref)
        #expect(t.token(ref: ref) == "x")
        t.delete(ref: ref)
        #expect(t.token(ref: ref) == nil)
    }

    @Test func errorBodyDecodes() {
        let e = APIClient.error(status: 423, data: Data(#"{"code":"locked","locked_until":"2026-11-22T12:03:00.000Z"}"#.utf8))
        guard case .server(423, "locked", let until?, nil) = e else { Issue.record("\(e)"); return }
        #expect(until == Date(timeIntervalSince1970: 1_795_348_980))
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var count: Int { lock.withLock { lines.count } }
}
