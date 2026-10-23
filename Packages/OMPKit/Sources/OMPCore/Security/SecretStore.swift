import Foundation

public protocol SecretStoring: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String?, for account: String) throws
}

#if canImport(Security)
import Security

/// Keychain-backed secret storage. Items are device-only and never synced.
public struct KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "com.ace.ompchat.secrets") {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if os(iOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderError.transport("Keychain 读取失败：\(status)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        var insert = base
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderError.transport("Keychain 写入失败：\(addStatus)")
        }
    }
}

/// Volatile store for previews and tests.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func secret(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func setSecret(_ value: String?, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }
}
#endif
