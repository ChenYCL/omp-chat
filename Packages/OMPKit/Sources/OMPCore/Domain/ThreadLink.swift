import Foundation

/// Official Codex `threadHeader.copyActions` app link: `ompchat://thread/<uuid>`.
/// The scheme is registered as `CFBundleURLTypes` in both apps and handled by
/// `.onOpenURL`, so a pasted link opens the thread it points at.
public enum ThreadLink {
    /// The link for a conversation, e.g. `ompchat://thread/UUID`.
    public static func url(for id: UUID) -> URL {
        URL(string: "ompchat://thread/\(id.uuidString)")!
    }

    /// Parses links built by `url(for:)`. Anything else — another scheme,
    /// another host, a missing or malformed UUID — is rejected; scheme and
    /// host compare case-insensitively because URLs are.
    public static func threadID(in url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "ompchat" else { return nil }
        guard url.host?.lowercased() == "thread" else { return nil }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty, !raw.contains("/") else { return nil }
        return UUID(uuidString: raw)
    }
}
