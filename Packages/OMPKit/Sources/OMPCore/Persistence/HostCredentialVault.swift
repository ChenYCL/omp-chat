import Foundation

/// Keeps the Mac's own relay credentials (LAN pairing token, hub room code) out
/// of `workspace.json`, mirroring `PairedDeviceVault` on the phone side.
///
/// Either value is enough for a phone to drive this Mac, so the document stores
/// them blank and the secret store holds the real ones. A value only leaves the
/// document after its vault write succeeded; a plaintext value found in the
/// document is the newest one and overwrites the vault.
public enum HostCredentialVault {
    public static let tokenAccount = "relay-host.token"
    public static let roomAccount = "relay-host.room"

    private static var fields: [(field: WritableKeyPath<AppSettings, String>, account: String)] {
        [(\.relayToken, tokenAccount), (\.relayRoomCode, roomAccount)]
    }

    /// Fills the credentials from the vault; `needsRewrite` asks the caller to
    /// save the document so a migrated plaintext value is dropped from it.
    public static func hydrate(_ settings: AppSettings, secrets: any SecretStoring) -> (settings: AppSettings, needsRewrite: Bool) {
        var settings = settings
        var needsRewrite = false
        for (field, account) in fields {
            if !settings[keyPath: field].isEmpty {
                if (try? secrets.setSecret(settings[keyPath: field], for: account)) != nil { needsRewrite = true }
            } else if let saved = (try? secrets.secret(for: account)) ?? nil {
                settings[keyPath: field] = saved
            }
        }
        return (settings, needsRewrite)
    }

    /// Writes the credentials to the vault and returns the settings as they
    /// should be persisted. An emptied field (e.g. a reset) clears its entry.
    public static func persistable(_ settings: AppSettings, secrets: any SecretStoring) -> AppSettings {
        var persisted = settings
        for (field, account) in fields {
            let value = settings[keyPath: field]
            if value.isEmpty {
                try? secrets.setSecret(nil, for: account)
            } else if (try? secrets.setSecret(value, for: account)) != nil {
                persisted[keyPath: field] = ""
            }
        }
        return persisted
    }
}
