import Foundation

/// Official Codex `threadHeader.forkActions`, reduced to what this app can do
/// honestly:
///
/// - `local`: a copy of the chat with no directory bound to it.
/// - `sameWorktree`: a copy that keeps pointing at the same directory.
/// - `worktree`: a new `git worktree` beside the repository, with the copy bound
///   to it. This needs a real git checkout, so it fails loudly when the
///   conversation is not in a repository or git refuses.
public enum ForkMode: String, Sendable, CaseIterable {
    case local
    case sameWorktree
    case worktree

    public var title: String {
        switch self {
        case .local: return "本地副本"
        case .sameWorktree: return "同一工作目录"
        case .worktree: return "新建 Worktree"
        }
    }
}

/// `git worktree add` as a value, so the arguments can be tested without a
/// repository and the command can be run by whoever owns the process spawner.
public enum WorktreeFork {
    public struct Plan: Equatable {
        public var arguments: [String]
        /// Where the new checkout will live.
        public var path: String
    }

    /// A deterministic, filesystem-safe name: the branch and directory share it.
    public static func slug(title: String, id: UUID) -> String {
        let allowed = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var slug = String(allowed)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 40 { slug = String(slug.prefix(40)) }
        if slug.isEmpty { slug = "thread" }
        return "\(slug)-\(id.uuidString.prefix(8).lowercased())"
    }

    /// The `git worktree add` invocation for a fork of `title`.
    public static func plan(title: String, id: UUID, repository: String) -> Plan {
        let name = slug(title: title, id: id)
        let path = (repository as NSString).deletingLastPathComponent + "/" + name
        return Plan(
            arguments: ["worktree", "add", "-b", name, path],
            path: path
        )
    }
}

/// Picks the git binary to run. `/usr/bin/git` goes through xcrun, which a
/// sandboxed app cannot always spawn, so the Homebrew builds are tried first.
public enum GitBinary {
    public static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    public static func resolve() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
