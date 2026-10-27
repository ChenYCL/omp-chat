import Foundation
import OMPCore

/// Which part of the composer's mention list a candidate belongs to
/// (official `composer.atMentionList.files` / `chats` / `browserTabs`,
/// `composer.skillMentionList`).
public enum MentionSection: String, Hashable, Sendable {
    case files, chats, tabs, skills
}

/// One row of the `@` / `$` list.
public struct MentionCandidate: Identifiable, Hashable, Sendable {
    /// What picking the row inserts.
    public var mention: ComposerMention
    public var section: MentionSection
    public var title: String
    /// Second line: a file's folder, a chat's last message, a tab's
    /// address, a skill's description.
    public var detail: String
    /// Right-hand label: a skill's source, 对话, 标签页.
    public var badge: String
    public var icon: String

    public var id: String { mention.token }

    public init(mention: ComposerMention, section: MentionSection, title: String, detail: String, badge: String, icon: String) {
        self.mention = mention
        self.section = section
        self.title = title
        self.detail = detail
        self.badge = badge
        self.icon = icon
    }
}

/// What one search of the list found, files first, then chats, then tabs.
public struct MentionSearchResult: Equatable, Sendable {
    public var candidates: [MentionCandidate]
    /// The working directory could not be listed: 无法搜索文件 (official
    /// `composer.atMentionList.fileSearchError`).
    public var fileSearchFailed: Bool

    public init(candidates: [MentionCandidate] = [], fileSearchFailed: Bool = false) {
        self.candidates = candidates
        self.fileSearchFailed = fileSearchFailed
    }
}

/// What the composer's mention lists search, kept off the main actor: the
/// files of a working directory and the skills of a thread, each cached
/// until refreshed (the list refreshes them when it opens).
///
/// In a git checkout git decides which files count
/// (`git ls-files -co --exclude-standard`), so `.gitignore` holds. Elsewhere
/// — or when git cannot run — a breadth-first walk lists them. Both skip
/// `.git`, `node_modules`, build output and hidden folders, and both stop at
/// `Limits`.
public actor MentionIndex {
    public struct Limits: Equatable, Sendable {
        /// Folder levels below the working directory that are listed.
        public var maxDepth: Int
        /// Directory entries the walk looks at, or paths taken from git,
        /// before the listing stops.
        public var maxEntries: Int

        public init(maxDepth: Int = 12, maxEntries: Int = 20_000) {
            self.maxDepth = maxDepth
            self.maxEntries = maxEntries
        }
    }

    public struct Listing: Equatable, Sendable {
        /// Regular files, relative to the directory, `/`-separated.
        public var files: [String]
        /// False when a limit cut the listing short.
        public var isComplete: Bool
        /// git listed them, so `.gitignore` was honoured.
        public var fromGit: Bool
    }

    public enum Failure: Error, Equatable {
        /// The directory is missing or cannot be read.
        case unreadable
    }

    /// Folders never listed, besides hidden ones.
    public static let skippedFolders: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", "dist", "target", "Pods", "Carthage", "__pycache__", "venv",
    ]
    /// Working directories whose listings are kept at once; past it the
    /// cache starts over.
    static let cachedDirectories = 8

    private let limits: Limits
    private var listings: [String: Listing] = [:]
    private var building: [String: Task<Listing, Error>] = [:]
    private var skills: [UUID: [Skill]] = [:]

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    // MARK: Files

    /// The listing of `directory`: the cached one, the one being built, or
    /// a new one when there is neither.
    public func files(in directory: String) async throws -> Listing {
        if let running = building[directory] { return try await running.value }
        if let cached = listings[directory] { return cached }
        return try await rebuild(directory)
    }

    /// Lists `directory` afresh, joining a build that is already running.
    @discardableResult
    public func refresh(_ directory: String) async throws -> Listing {
        if let running = building[directory] { return try await running.value }
        return try await rebuild(directory)
    }

    /// Up to `limit` files of `directory` that match `query`, best first.
    public func search(_ directory: String, query: String, limit: Int) async throws -> [String] {
        let listing = try await files(in: directory)
        return Self.rank(listing.files, query: query, limit: limit)
    }

    private func rebuild(_ directory: String) async throws -> Listing {
        let limits = self.limits
        let task = Task.detached(priority: .userInitiated) { try Self.list(directory, limits: limits) }
        building[directory] = task
        defer { building[directory] = nil }
        do {
            let listing = try await task.value
            if listings[directory] == nil, listings.count >= Self.cachedDirectories { listings.removeAll() }
            listings[directory] = listing
            return listing
        } catch {
            listings[directory] = nil
            throw error
        }
    }

    /// The absolute path `query` names when it is one (`/…`, `~/…`) of an
    /// existing regular file: the one way to pick a file outside the
    /// working directory.
    public func existingFile(_ query: String, home: String) -> String? {
        guard query.hasPrefix("/") || query.hasPrefix("~/"),
              let path = AgentPathPolicy.resolve(query, workingDirectory: nil, home: home) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return path
    }

    // MARK: Skills

    /// The thread's skills as last loaded; nil before the first load.
    public func cachedSkills(for conversationID: UUID) -> [Skill]? {
        skills[conversationID]
    }

    /// Skills matching `query` (case-insensitive): the name starts with it,
    /// then the name contains it, then the description does. An empty query
    /// keeps them all in catalog order (project, local, plugins).
    public nonisolated static func rankSkills(_ skills: [Skill], query: String) -> [Skill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return skills }
        var tiers: [[Skill]] = [[], [], []]
        for skill in skills {
            let name = skill.name.lowercased()
            if name.hasPrefix(needle) {
                tiers[0].append(skill)
            } else if name.contains(needle) {
                tiers[1].append(skill)
            } else if skill.description.lowercased().contains(needle) || skill.shortDescription?.lowercased().contains(needle) == true {
                tiers[2].append(skill)
            }
        }
        return tiers.flatMap { $0 }
    }

    /// Reads the skills under `roots` (`ChatAppModel.skillRoots(for:)`) and
    /// keeps them for the thread.
    @discardableResult
    public func loadSkills(for conversationID: UUID, roots: [SkillRoot]) -> [Skill] {
        let loaded = SkillCatalog.load(roots: roots).skills
        skills[conversationID] = loaded
        return loaded
    }

    // MARK: Ranking

    /// Files matching `query` (case-insensitive), best first: the file name
    /// starts with it, then the name contains it, then the path does, then
    /// the path holds its characters in order. Shorter paths first within a
    /// tier. An empty query matches nothing.
    public nonisolated static func rank(_ files: [String], query: String, limit: Int) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, limit > 0 else { return [] }
        var tiers: [[String]] = [[], [], [], []]
        for path in files {
            let lowered = path.lowercased()
            let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
            if name.hasPrefix(needle) {
                tiers[0].append(path)
            } else if name.contains(needle) {
                tiers[1].append(path)
            } else if lowered.contains(needle) {
                tiers[2].append(path)
            } else if isSubsequence(needle, of: lowered) {
                tiers[3].append(path)
            }
        }
        var ranked: [String] = []
        for tier in tiers {
            guard ranked.count < limit else { break }
            let sorted = tier.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            ranked += sorted.prefix(limit - ranked.count)
        }
        return ranked
    }

    private nonisolated static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    // MARK: Listing

    nonisolated static func list(_ directory: String, limits: Limits) throws -> Listing {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.unreadable
        }
        #if os(macOS)
        if isInsideRepository(directory), let listing = gitListing(directory, limits: limits) { return listing }
        #endif
        return try walk(directory, limits: limits)
    }

    /// Breadth-first, so a limit keeps the files nearest the top. Symlinks
    /// are not followed, which also rules out cycles.
    nonisolated static func walk(_ root: String, limits: Limits) throws -> Listing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var queue: [(url: URL, relative: String, depth: Int)] = [(URL(fileURLWithPath: root, isDirectory: true), "", 0)]
        var next = 0
        var files: [String] = []
        var looked = 0
        var complete = true
        walking: while next < queue.count {
            let folder = queue[next]
            next += 1
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: keys)
            } catch {
                if folder.relative.isEmpty { throw Failure.unreadable }
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                looked += 1
                if looked > limits.maxEntries {
                    complete = false
                    break walking
                }
                let name = child.lastPathComponent
                let path = folder.relative.isEmpty ? name : folder.relative + "/" + name
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    guard !name.hasPrefix("."), !skippedFolders.contains(name) else { continue }
                    if folder.depth + 1 <= limits.maxDepth {
                        queue.append((child, path, folder.depth + 1))
                    } else {
                        complete = false
                    }
                } else if values.isRegularFile == true {
                    files.append(path)
                }
            }
        }
        return Listing(files: files, isComplete: complete, fromGit: false)
    }

    /// Whether a git listing may keep `path`: no hidden or skipped folder on
    /// the way, and no deeper than `maxDepth` folders.
    nonisolated static func keeps(_ path: String, maxDepth: Int) -> Bool {
        let components = path.split(separator: "/")
        guard !components.isEmpty, components.count - 1 <= maxDepth else { return false }
        return !components.dropLast().contains { $0.hasPrefix(".") || skippedFolders.contains(String($0)) }
    }

    #if os(macOS)
    /// A `.git` (folder, or file for a worktree) in the directory or above.
    nonisolated static func isInsideRepository(_ directory: String) -> Bool {
        var current = (directory as NSString).standardizingPath
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    /// `git ls-files -co --exclude-standard -z` in `directory`: tracked and
    /// untracked files that are not ignored, relative to it. Nil when git is
    /// missing or fails, so the caller walks instead. Read with blocking
    /// `read(2)` — `FileHandle` reads deliver nothing off a run loop — and
    /// stopped once `maxEntries` paths have come.
    nonisolated static func gitListing(_ directory: String, limits: Limits) -> Listing? {
        guard let git = GitBinary.resolve() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["ls-files", "-co", "--exclude-standard", "-z"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        // Sandboxed, HOME is the app container; git reads the account's own
        // config (core.excludesFile) from the real one.
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            environment["HOME"] = String(cString: home)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending: [UInt8] = []
        var files: [String] = []
        var taken = 0
        var complete = true
        reading: while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            var start = 0
            while let end = pending[start...].firstIndex(of: 0) {
                let path = String(decoding: pending[start..<end], as: UTF8.self)
                start = end + 1
                taken += 1
                if taken > limits.maxEntries {
                    complete = false
                    break reading
                }
                var isDirectory: ObjCBool = false
                // `-c` still lists tracked files deleted from the checkout;
                // a submodule is listed as its folder.
                if keeps(path, maxDepth: limits.maxDepth),
                   FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(path), isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    files.append(path)
                }
            }
            pending.removeFirst(start)
        }
        if !complete { process.terminate() }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        if complete, process.terminationStatus != 0 { return nil }
        return Listing(files: files, isComplete: complete, fromGit: true)
    }
    #endif
}
