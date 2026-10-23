import Foundation

/// Reads lightweight git facts for a working tree without shelling out.
public enum GitInfo {
    /// Current branch name, or short SHA when detached. Nil outside a repo.
    public static func branch(at directory: URL) -> String? {
        let head = directory
            .appendingPathComponent(".git", isDirectory: false)
        let headFile = head.appendingPathComponent("HEAD")
        guard FileManager.default.fileExists(atPath: headFile.path) else { return nil }
        guard let raw = try? String(contentsOf: headFile, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: ") {
            let ref = trimmed.dropFirst(5)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
        }
        return String(trimmed.prefix(7))
    }

    /// Abbreviates a path with `~` for the home directory.
    public static func tildified(_ path: String) -> String {
        let home = Self.homeDirectory().path
        guard path.hasPrefix(home) else { return path }
        let suffix = path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    private static func homeDirectory() -> URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
