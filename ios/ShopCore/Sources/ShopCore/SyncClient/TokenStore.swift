import Foundation
import Security

/// 设备令牌存哪儿（§3.1：令牌只在登录响应里出现一次，手机存钥匙串）。本地库只记条目名 `tokenRef`。
/// 当前会话和退役会话（恢复队列要用旧令牌，§4.5）的令牌都按各自的 `tokenRef` 存，退役会话传完后由 S22b 删。
public protocol TokenStore: Sendable {
    func save(_ token: String, ref: String) throws
    /// 钥匙串里**确实没有**这个条目才返回 nil；读不出来（例如重启后首次解锁前 `errSecInteractionNotAllowed`）抛
    /// `TokenReadError`，调用方不能把它当成「没登录」（PR #35 Fable 可选 2）
    func token(ref: String) throws -> String?
    func delete(ref: String)
}

/// 钥匙串读不出来（不是「没有」）
public struct TokenReadError: Error, Equatable, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
}

public enum TokenRef {
    /// 每次登录设备 id 都是新的，条目名跟着设备 id 走
    public static func forDevice(_ id: UUID) -> String { "device.\(id.uuidString.lowercased())" }
}

/// 钥匙串：`kSecClassGenericPassword`，只在这台设备上、首次解锁后可读，不进 iCloud 钥匙串、不进备份迁移。
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public init(service: String = "cn.yuanhuishop.zhangben.device-token") { self.service = service }

    private func base(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ref]
    }

    public func save(_ token: String, ref: String) throws {
        SecItemDelete(base(ref) as CFDictionary)
        var q = base(ref)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw ShopCoreError.invalid("钥匙串写入失败（\(st)）") }
    }

    public func token(ref: String) throws -> String? {
        var q = base(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return try Self.interpret(status: st, data: out as? Data)
    }

    /// 只有 `errSecItemNotFound` 算「没有」；其他失败一律抛错
    static func interpret(status: OSStatus, data: Data?) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data, let s = String(data: data, encoding: .utf8) else { throw TokenReadError(status: status) }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw TokenReadError(status: status)
        }
    }

    public func delete(ref: String) { SecItemDelete(base(ref) as CFDictionary) }

    /// Debug 夹具 / 测试：清掉本 App 的全部令牌
    public func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// 单元测试用
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// 测试用：设了就模拟「钥匙串读不出来」
    public var readFailure: Int32? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    private var failure: Int32?
    public init() {}
    public func save(_ token: String, ref: String) throws { lock.withLock { items[ref] = token } }
    public func token(ref: String) throws -> String? {
        try lock.withLock {
            if let failure { throw TokenReadError(status: failure) }
            return items[ref]
        }
    }
    public func delete(ref: String) { lock.withLock { _ = items.removeValue(forKey: ref) } }
}
