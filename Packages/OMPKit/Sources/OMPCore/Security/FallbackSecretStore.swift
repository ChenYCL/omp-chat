import Foundation

/// Keychain-first secret storage with a sandboxed file fallback.
///
/// Ad-hoc signed development builds can be refused Keychain access
/// (`errSecMissingEntitlement`); without the fallback the app would be
/// unusable while every production build still gets full Keychain storage.
public struct FallbackSecretStore: SecretStoring {
    private let primary: (any SecretStoring)?
    private let fallback: (any SecretStoring)?

    public init(
        primary: (any SecretStoring)? = nil,
        fileFallback: FileSecretVault = .defaultVault()
    ) {
        self.primary = primary
        self.fallback = fileFallback
    }

    public func secret(for account: String) throws -> String? {
        if let primary {
            do {
                if let value = try primary.secret(for: account) { return value }
            } catch {
                // Fall through to the file vault.
            }
        }
        return try fallback?.secret(for: account)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let primary else {
            try fallback?.setSecret(value, for: account)
            return
        }
        do {
            try primary.setSecret(value, for: account)
        } catch {
            guard let fallback else { throw error }
            try fallback.setSecret(value, for: account)
        }
    }
}

/// JSON vault for API keys, written with owner-only permissions.
public final class FileSecretVault: SecretStoring, @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultVault() -> FileSecretVault {
        let directory = FileConversationStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileSecretVault(fileURL: directory.appendingPathComponent("secrets.json"))
    }

    public func secret(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try read().secrets[account]
    }

    public func setSecret(_ value: String?, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var document = try read()
        if let value, !value.isEmpty {
            document.secrets[account] = value
        } else {
            document.secrets.removeValue(forKey: account)
        }
        try write(document)
    }

    private struct Document: Codable {
        var secrets: [String: String] = [:]
    }

    private func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return Document() }
        return (try? JSONDecoder().decode(Document.self, from: data)) ?? Document()
    }

    private func write(_ document: Document) throws {
        let data = try JSONEncoder().encode(document)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
