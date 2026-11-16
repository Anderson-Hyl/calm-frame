import Foundation
import Security

/// Keychain 的最小口：读写字符串。真实现走 SecItem；测试用内存替身。
public protocol KeychainStoring: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// 真实现：generic password，service 固定为 bundle ID。
public final class KeychainStore: KeychainStoring {
    private let service: String

    public init(service: String = "app.calmframe.dev") {
        self.service = service
    }

    public func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    public func set(_ value: String?, forKey key: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

/// 测试替身：内存字典 + 锁，不碰真 Keychain。
public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.withLock { storage[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock {
            if let value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }
}

/// 登录态的本地存根：服务端 JWT + appleSub + 余额。
/// 长期持有的是服务端 JWT（30 天）；Apple identityToken 只发一次换 JWT，绝不存这里。
/// 故意不标 @MainActor：AuthViewModel 的默认参数要在非隔离的 property initializer
/// 里构造它（标了会报 "call to main actor-isolated initializer in a synchronous
/// nonisolated context"）。线程安全靠 Keychain 本身（Security 框架线程安全）
/// 与内存替身的锁；实际调用方只有 @MainActor 的 AuthViewModel。
public final class SessionStore {
    public private(set) var serverToken: String?
    public private(set) var appleSub: String?
    public private(set) var balance: Int?

    private let keychain: any KeychainStoring

    private enum Key {
        static let token = "serverToken"
        static let appleSub = "appleSub"
        static let balance = "balance"
    }

    public init(keychain: any KeychainStoring = KeychainStore()) {
        self.keychain = keychain
        self.serverToken = keychain.string(forKey: Key.token)
        self.appleSub = keychain.string(forKey: Key.appleSub)
        if let rawBalance = keychain.string(forKey: Key.balance) {
            self.balance = Int(rawBalance)
        }
    }

    public var isSignedIn: Bool {
        serverToken != nil
    }

    public func save(token: String, appleSub: String, balance: Int) {
        keychain.set(token, forKey: Key.token)
        keychain.set(appleSub, forKey: Key.appleSub)
        keychain.set(String(balance), forKey: Key.balance)
        self.serverToken = token
        self.appleSub = appleSub
        self.balance = balance
    }

    public func updateBalance(_ balance: Int) {
        keychain.set(String(balance), forKey: Key.balance)
        self.balance = balance
    }

    /// 登出：清掉本地全部登录态（不删账号——账号在服务端）。
    public func clear() {
        keychain.set(nil, forKey: Key.token)
        keychain.set(nil, forKey: Key.appleSub)
        keychain.set(nil, forKey: Key.balance)
        serverToken = nil
        appleSub = nil
        balance = nil
    }
}
