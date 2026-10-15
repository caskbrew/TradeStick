import Domain
import Foundation
import Security

/// Where API keys live. Secrets never go to the database, defaults or logs.
public protocol CredentialStore: Sendable {
    func load(exchange: String) -> APICredentials?
    func save(_ credentials: APICredentials, exchange: String) throws
    func remove(exchange: String) throws
}

public struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    public var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
}

/// macOS Keychain, one generic-password item per exchange. `service` differs between the installed app and
/// dev builds, so a dev build never sees the installed app's keys.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String) { self.service = service }

    private func query(_ exchange: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: exchange]
    }

    public func load(exchange: String) -> APICredentials? {
        var q = query(exchange)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = dict["key"], let secret = dict["secret"] else { return nil }
        return APICredentials(key: key, secret: secret)
    }

    public func save(_ credentials: APICredentials, exchange: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["key": credentials.key, "secret": credentials.secret])
        let update = SecItemUpdate(query(exchange) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(exchange)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(exchange: String) throws {
        let status = SecItemDelete(query(exchange) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: APICredentials] = [:]
    public init() {}
    public func load(exchange: String) -> APICredentials? { lock.withLock { items[exchange] } }
    public func save(_ credentials: APICredentials, exchange: String) throws { lock.withLock { items[exchange] = credentials } }
    public func remove(exchange: String) throws { _ = lock.withLock { items.removeValue(forKey: exchange) } }
}
