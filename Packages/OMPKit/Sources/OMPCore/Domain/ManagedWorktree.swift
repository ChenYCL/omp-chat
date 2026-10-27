import Foundation

/// One Codex-managed worktree this app created, persisted in the workspace
/// document (`managedWorktrees`). Codex's managed worktrees live under
/// `$CODEX_HOME/worktrees`, start detached at a branch's HEAD commit and are
/// meant to feel lightweight and disposable; this registry is what cleanup,
/// snapshots and handoff build on.
public struct ManagedWorktree: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Absolute path of the checkout (`<root>/<repo-name>/<slug>`).
    public var path: String
    /// Absolute path of the repository the worktree was created from.
    public var sourceRoot: String
    /// The commit `git worktree add --detach` checked out.
    public var baseCommit: String
    /// Nil while HEAD is detached (the Codex default); set once a branch is
    /// created in the worktree.
    public var branch: String?
    /// The branch the composer picked as the starting point, for display.
    public var baseBranch: String?
    public var createdAt: Date
    /// The local environment file the setup ran from, relative to the
    /// repository root (`.codex/environments/…`); nil when none was selected.
    public var environmentPath: String?
    /// Chats bound to this worktree (usually exactly one).
    public var conversationIDs: [UUID]
    /// Set before deletion so a reopened chat can offer to restore.
    public var snapshot: ManagedWorktreeSnapshot?
    /// Set when the worktree was deleted; the entry stays for history.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        path: String,
        sourceRoot: String,
        baseCommit: String,
        branch: String? = nil,
        baseBranch: String? = nil,
        createdAt: Date = Date(),
        environmentPath: String? = nil,
        conversationIDs: [UUID] = [],
        snapshot: ManagedWorktreeSnapshot? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.sourceRoot = sourceRoot
        self.baseCommit = baseCommit
        self.branch = branch
        self.baseBranch = baseBranch
        self.createdAt = createdAt
        self.environmentPath = environmentPath
        self.conversationIDs = conversationIDs
        self.snapshot = snapshot
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// Tolerant decode: every field but `id`/`path`/`sourceRoot`/`baseCommit`
    /// is optional, so a document written by an older build still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        sourceRoot = try container.decodeIfPresent(String.self, forKey: .sourceRoot) ?? ""
        baseCommit = try container.decodeIfPresent(String.self, forKey: .baseCommit) ?? ""
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        environmentPath = try container.decodeIfPresent(String.self, forKey: .environmentPath)
        conversationIDs = try container.decodeIfPresent([UUID].self, forKey: .conversationIDs) ?? []
        snapshot = try container.decodeIfPresent(ManagedWorktreeSnapshot.self, forKey: .snapshot)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, sourceRoot, baseCommit, branch, baseBranch, createdAt
        case environmentPath, conversationIDs, snapshot, deletedAt
    }

    /// Decodes the document's worktree list one entry at a time, dropping any
    /// that cannot be read so one damaged row never stops the workspace
    /// opening (same contract as `ScheduledTask.decodeList`).
    public static func decodeList<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> [ManagedWorktree] {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return [] }
        var list = try container.nestedUnkeyedContainer(forKey: key)
        var worktrees: [ManagedWorktree] = []
        while !list.isAtEnd {
            if try list.decodeNil() { continue }
            if let worktree = try? list.decode(ManagedWorktree.self) {
                worktrees.append(worktree)
            } else if (try? list.decode(Skipped.self)) == nil {
                // Neither decode moved past the element; stop rather than spin.
                break
            }
        }
        return worktrees
    }

    /// Consumes one element of any shape.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// A pre-deletion copy of a worktree's work, kept in the source repository so
/// a chat whose worktree was deleted can offer to restore it.
public struct ManagedWorktreeSnapshot: Codable, Hashable, Sendable {
    /// Ref the snapshot commit hangs on: `refs/omp/snapshots/<uuid>` in the
    /// source repository.
    public var ref: String
    /// Snapshot commit: its tree is the full working state.
    public var commit: String
    /// HEAD of the worktree when the snapshot was taken.
    public var head: String
    public var createdAt: Date

    public init(ref: String, commit: String, head: String, createdAt: Date = Date()) {
        self.ref = ref
        self.commit = commit
        self.head = head
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decodeIfPresent(String.self, forKey: .ref) ?? ""
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? ""
        head = try container.decodeIfPresent(String.self, forKey: .head) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case ref, commit, head, createdAt
    }
}

/// Reads a repository's `.worktreeinclude` and decides which of git's ignored
/// files a new managed worktree receives (official Codex "Copy ignored local
/// files into managed worktrees"). Patterns are gitignore-style: `*`, `?`,
/// `**`, leading `/` anchors, trailing `/` marks directories, `!` negates
/// (last match wins), `#` comments. An ignored `AGENTS.override.md` is always
/// selected, as in Codex.
public enum WorktreeInclude {
    /// The file's meaningful lines, without comments and blank lines. A
    /// missing file means an empty list.
    public static func patterns(inRepositoryRoot root: String) -> [String] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".worktreeinclude")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { meaningfulLine($0) }
    }

    /// Which ignored files (repository-root-relative, `/` separated) the new
    /// worktree receives. Only files git reports as ignored ever reach this,
    /// so tracked files cannot sneak in.
    public static func select(patterns: [String], amongIgnoredFiles files: [String]) -> [String] {
        // The automatic rule first, so an explicit `!AGENTS.override.md` wins.
        let compiled = ([automatic] + patterns).compactMap(parse)
        guard !compiled.isEmpty else { return [] }
        var selected: [String] = []
        for file in files {
            let segments = file.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            if copied(segments, patterns: compiled) { selected.append(file) }
        }
        return selected
    }

    /// Copies the selected files into the worktree. Source symlinks are
    /// skipped and files already in the checkout are never overwritten, as in
    /// Codex. Returns the paths actually copied.
    public static func copy(relativePaths: [String], from sourceRoot: String, to worktreeRoot: String) throws -> [String] {
        let fileManager = FileManager.default
        var copied: [String] = []
        for relative in relativePaths {
            let clean = relative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let source = (sourceRoot as NSString).appendingPathComponent(clean)
            let destination = (worktreeRoot as NSString).appendingPathComponent(clean)
            guard let attributes = try? fileManager.attributesOfItem(atPath: source),
                  let type = attributes[.type] as? FileAttributeType, type == .typeRegular else { continue }
            // lstat semantics: a dangling destination symlink counts as there.
            if (try? fileManager.attributesOfItem(atPath: destination)) != nil { continue }
            try fileManager.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(atPath: source, toPath: destination)
            // Keep the executable bit an ignored helper script may carry.
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination)
            }
            copied.append(clean)
        }
        return copied
    }

    // MARK: - Pattern internals

    /// Always copied when git ignores it, as in Codex.
    public static let automatic = "AGENTS.override.md"

    struct Pattern {
        var negated = false
        var directoryOnly = false
        /// Anchored patterns match from the root; bare names match at any
        /// depth.
        var anchored = false
        var segments: [String] = []
    }

    /// Strips comments and trailing whitespace (unless the space is escaped),
    /// keeping the raw pattern text.
    static func meaningfulLine(_ raw: String) -> String? {
        var line = raw
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if line.hasPrefix("#") { return nil }
        if line.hasPrefix("\\#") || line.hasPrefix("\\!") { line.removeFirst() }
        while let last = line.last, last == " " || last == "\t" {
            if line.dropLast().hasSuffix("\\") { break } // escaped trailing space
            line = String(line.dropLast())
        }
        return line.isEmpty ? nil : line
    }

    static func parse(_ raw: String) -> Pattern? {
        var pattern = Pattern()
        var line = raw
        if line.hasPrefix("!") {
            pattern.negated = true
            line.removeFirst()
        }
        if line.hasSuffix("/") {
            pattern.directoryOnly = true
            line.removeLast()
        }
        if line.hasPrefix("/") {
            pattern.anchored = true
            line.removeFirst()
        } else if line.hasPrefix("./") {
            pattern.anchored = true
            line.removeFirst(2)
        }
        if line.contains("/") { pattern.anchored = true }
        pattern.segments = line.split(separator: "/").map(String.init)
        return pattern.segments.isEmpty ? nil : pattern
    }

    /// Git's rule, mirrored for copying: walking from the root, a directory
    /// matched by a positive pattern is copied wholesale and nothing below can
    /// opt out; a negated directory just stops that pattern from copying and
    /// deeper positives still apply. The file itself: last match wins.
    static func copied(_ segments: [String], patterns: [Pattern]) -> Bool {
        for depth in 1..<segments.count {
            let directory = Array(segments.prefix(depth))
            var last: Pattern?
            for pattern in patterns where matches(pattern, directory, isDirectory: true) { last = pattern }
            if let last, !last.negated { return true }
        }
        var last: Pattern?
        for pattern in patterns where !pattern.directoryOnly {
            if matches(pattern, segments, isDirectory: false) { last = pattern }
        }
        return last.map { !$0.negated } ?? false
    }

    static func matches(_ pattern: Pattern, _ path: [String], isDirectory: Bool) -> Bool {
        if pattern.directoryOnly, !isDirectory { return false }
        let effective = pattern.anchored ? pattern.segments : ["**"] + pattern.segments
        return matchFrom(effective, 0, path, 0)
    }

    static func matchFrom(_ pattern: [String], _ patternIndex: Int, _ path: [String], _ pathIndex: Int) -> Bool {
        if patternIndex == pattern.count { return pathIndex == path.count }
        let head = pattern[patternIndex]
        if head == "**" {
            let rest = patternIndex + 1
            // Trailing `**` matches what is below, not the level itself.
            if rest == pattern.count { return pathIndex < path.count }
            var offset = pathIndex
            while offset <= path.count {
                if matchFrom(pattern, rest, path, offset) { return true }
                offset += 1
            }
            return false
        }
        guard pathIndex < path.count, globMatch(head, path[pathIndex]) else { return false }
        return matchFrom(pattern, patternIndex + 1, path, pathIndex + 1)
    }

    /// fnmatch on one path segment: `*` and `?` never cross `/` (segments are
    /// already split), `[...]` classes with ranges and a leading `!`, `\x`
    /// escapes.
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        var p = pattern.startIndex
        var n = name.startIndex
        var starPattern: String.Index?
        var starName = name.startIndex
        while n < name.endIndex {
            if p < pattern.endIndex {
                switch pattern[p] {
                case "*":
                    starPattern = pattern.index(after: p)
                    starName = n
                    p = starPattern!
                    continue
                case "?":
                    p = pattern.index(after: p)
                    n = name.index(after: n)
                    continue
                case "\\":
                    let next = pattern.index(after: p)
                    if next < pattern.endIndex {
                        if name[n] == pattern[next] {
                            p = pattern.index(after: next)
                            n = name.index(after: n)
                            continue
                        }
                    } else if name[n] == "\\" {
                        p = next
                        n = name.index(after: n)
                        continue
                    }
                case "[":
                    if let result = matchClass(pattern, from: p, character: name[n]) {
                        if result.matched {
                            p = result.after
                            n = name.index(after: n)
                            continue
                        }
                    } else if name[n] == "[" {
                        // Unterminated class: a literal bracket.
                        p = pattern.index(after: p)
                        n = name.index(after: n)
                        continue
                    }
                default:
                    if name[n] == pattern[p] {
                        p = pattern.index(after: p)
                        n = name.index(after: n)
                        continue
                    }
                }
            }
            // Mismatch: let the last star swallow one more character.
            if let sp = starPattern, starName < name.endIndex {
                p = sp
                starName = name.index(after: starName)
                n = starName
                continue
            }
            return false
        }
        while p < pattern.endIndex, pattern[p] == "*" { p = pattern.index(after: p) }
        return p == pattern.endIndex
    }

    /// Matches a `[...]` class. Returns nil when the bracket never closes (the
    /// caller treats the `[` as a literal).
    static func matchClass(_ pattern: String, from start: String.Index, character: Character?) -> (matched: Bool, after: String.Index)? {
        var index = pattern.index(after: start)
        var negated = false
        if index < pattern.endIndex, pattern[index] == "!" || pattern[index] == "^" {
            negated = true
            index = pattern.index(after: index)
        }
        var members: [Character] = []
        var ranges: [ClosedRange<Character>] = []
        var closed = false
        while index < pattern.endIndex {
            var current = pattern[index]
            if current == "]" {
                closed = true
                index = pattern.index(after: index)
                break
            }
            if current == "\\", index < pattern.index(before: pattern.endIndex) {
                index = pattern.index(after: index)
                current = pattern[index]
            }
            let next = pattern.index(after: index)
            if next < pattern.endIndex, pattern[next] == "-" {
                let afterDash = pattern.index(after: next)
                if afterDash < pattern.endIndex, pattern[afterDash] != "]" {
                    ranges.append(current...pattern[afterDash])
                    index = pattern.index(after: afterDash)
                    continue
                }
            }
            members.append(current)
            index = next
        }
        guard closed else { return nil }
        guard let character else { return (false, index) }
        let hit = members.contains(character) || ranges.contains { $0.contains(character) }
        return (hit != negated, index)
    }
}

/// Where managed worktrees live and how their paths are shaped.
public enum ManagedWorktreeLayout {
    /// Application Support `OMPChat/worktrees` — the store's directory, so
    /// `OMPCHAT_STORE_DIR` redirects probes the same way it redirects the
    /// workspace. Codex uses `$CODEX_HOME/worktrees`; this app has neither a
    /// CODEX_HOME nor sandbox rights to create folders in the account home,
    /// so the app data directory takes that role.
    public static func defaultRoot() -> URL {
        FileConversationStore.defaultDirectory().appendingPathComponent("worktrees", isDirectory: true)
    }

    /// `<root>/<repo-name>/<slug>` — grouped per repository like Codex's
    /// `$CODEX_HOME/worktrees/<repo>/<slug>`.
    public static func managedPath(root: String, sourceRoot: String, slug: String) -> String {
        var base = root
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var repo = sourceRoot
        while repo.count > 1, repo.hasSuffix("/") { repo.removeLast() }
        let name = (repo as NSString).lastPathComponent
        return slug.isEmpty ? base + "/" + name : base + "/" + name + "/" + slug
    }
}
