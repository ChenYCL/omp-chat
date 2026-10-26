import Foundation

/// Where a skill was found. Precedence for same-named skills follows the
/// order roots are passed to `SkillCatalog.load(roots:)`.
public enum SkillScope: Hashable, Sendable {
    /// `.agents/skills` in a folder between the working directory and its
    /// repository root.
    case repository
    /// `~/.agents/skills`.
    case user
    /// A plugin's skills; their names carry a `<plugin>:` prefix.
    case plugin(String)

    public var title: String {
        switch self {
        case .repository: "仓库"
        case .user: "用户"
        case .plugin(let id): "插件 · \(id)"
        }
    }
}

public struct SkillRoot: Hashable, Sendable {
    public var path: String
    public var scope: SkillScope

    public init(path: String, scope: SkillScope) {
        self.path = path
        self.scope = scope
    }
}

/// One `SKILL.md`, by its frontmatter (developers.openai.com/codex/skills).
public struct Skill: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Frontmatter `name` (or the folder name), prefixed `<plugin>:` for
    /// plugin skills as Codex namespaces them.
    public var name: String
    /// One line; whitespace collapsed.
    public var description: String
    /// `metadata.short-description`.
    public var shortDescription: String?
    /// Absolute path of the `SKILL.md`.
    public var path: String
    public var scope: SkillScope
    /// `agents/openai.yaml` `policy.allow_implicit_invocation`; when false
    /// the skill is never offered to the model here, since this app has no
    /// explicit `$skill` invocation.
    public var allowsImplicitInvocation: Bool

    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// A skill that could not be used, and why.
public struct SkillProblem: Hashable, Sendable {
    public var path: String
    public var reason: String
}

/// How long the model-visible skills list may be. Codex gives it 2% of the
/// model's context window (tokens ≈ UTF-8 bytes / 4), or 8,000 characters
/// when the window is unknown.
public enum SkillPromptBudget: Equatable, Sendable {
    case characters(Int)
    case tokens(Int)

    public static let defaultCharacters = 8_000

    public static func forContextWindow(_ tokens: Int?) -> SkillPromptBudget {
        guard let tokens, tokens > 0 else { return .characters(defaultCharacters) }
        return .tokens(max(1, tokens * 2 / 100))
    }

    var limit: Int {
        switch self {
        case .characters(let value), .tokens(let value): value
        }
    }

    /// Cost of one list line plus its newline.
    func cost(_ line: String) -> Int {
        switch self {
        case .characters: line.count + 1
        case .tokens: (line.utf8.count + 1 + 3) / 4
        }
    }
}

/// Every skill a thread can use.
///
/// Duplicate names: the root passed first wins — the repository folder
/// nearest the working directory, then folders up to the repository root,
/// then `~/.agents/skills`, then plugins (whose names never collide with
/// these, being `<plugin>:`-prefixed). Inside one root the first path in
/// sorted order wins. The losers are kept in `shadowed` for the settings
/// list. The same `SKILL.md` reached twice (overlapping roots, symlinks) is
/// listed once.
public struct SkillCatalog: Equatable, Sendable {
    public static let fileName = "SKILL.md"
    public static let maxNameLength = 64
    public static let maxDescriptionCharacters = 1_024
    /// Codex's recursive scan depth below a skills root.
    static let maxScanDepth = 6
    static let maxDirectoriesPerRoot = 2_000

    public var skills: [Skill]
    /// Same-named skills that lost to an earlier one.
    public var shadowed: [Skill]
    public var problems: [SkillProblem]

    public init(skills: [Skill] = [], shadowed: [Skill] = [], problems: [SkillProblem] = []) {
        self.skills = skills
        self.shadowed = shadowed
        self.problems = problems
    }

    // MARK: Roots

    /// `.agents/skills` from `workingDirectory` up to its repository root,
    /// nearest first; only the working directory's own when there is no
    /// repository. Missing folders are left out.
    public static func repositoryRoots(workingDirectory: String) -> [SkillRoot] {
        AgentsMDLoader.searchDirectories(for: workingDirectory).reversed().compactMap { directory in
            let path = (directory as NSString).appendingPathComponent(".agents/skills")
            return isDirectory(path) ? SkillRoot(path: path, scope: .repository) : nil
        }
    }

    /// `<home>/.agents/skills`, when it exists.
    public static func userRoot(home: String) -> SkillRoot? {
        let path = (home as NSString).appendingPathComponent(".agents/skills")
        return isDirectory(path) ? SkillRoot(path: path, scope: .user) : nil
    }

    // MARK: Loading

    public static func load(roots: [SkillRoot]) -> SkillCatalog {
        var catalog = SkillCatalog()
        var seenFiles = Set<String>()
        var byName: [String: Skill] = [:]
        for root in roots {
            for path in skillFiles(under: root.path) {
                guard seenFiles.insert(PluginPath.real(path)).inserted else { continue }
                let skill: Skill
                do {
                    skill = try parse(path: path, scope: root.scope)
                } catch {
                    catalog.problems.append(SkillProblem(path: path, reason: (error as? SkillError)?.message ?? error.localizedDescription))
                    continue
                }
                if byName[skill.name] != nil {
                    catalog.shadowed.append(skill)
                } else {
                    byName[skill.name] = skill
                    catalog.skills.append(skill)
                }
            }
        }
        return catalog
    }

    /// Reads one `SKILL.md` (and its optional `agents/openai.yaml`).
    public static func parse(path: String, scope: SkillScope) throws -> Skill {
        guard let data = FileManager.default.contents(atPath: path) else { throw SkillError(message: "无法读取文件") }
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let front = try frontmatter(String(decoding: data, as: UTF8.self), defaultName: folder)
        let name: String
        if case .plugin(let id) = scope { name = "\(id):\(front.name)" } else { name = front.name }
        return Skill(
            name: name, description: front.description, shortDescription: front.shortDescription,
            path: path, scope: scope,
            allowsImplicitInvocation: implicitInvocationAllowed(skillDirectory: (path as NSString).deletingLastPathComponent)
        )
    }

    public struct SkillError: Error, Equatable {
        public var message: String
    }

    public struct Frontmatter: Equatable, Sendable {
        public var name: String
        public var description: String
        public var shortDescription: String?
    }

    /// Codex's SKILL.md rules: a `---` line first, YAML until the next
    /// `---`; `name` defaults to the folder name and may be at most 64
    /// characters; `description` is required. Both are collapsed to one line.
    /// A leading BOM and CRLF line endings are accepted.
    public static func frontmatter(_ contents: String, defaultName: String) throws -> Frontmatter {
        var text = contents
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.popFirst()?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw SkillError(message: "缺少用 --- 包围的 YAML frontmatter")
        }
        var yaml: [String] = []
        var closed = false
        while let line = lines.popFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            yaml.append(line)
        }
        guard closed, !yaml.isEmpty else { throw SkillError(message: "缺少用 --- 包围的 YAML frontmatter") }

        let fields: [String: MiniYAML.Value]
        do {
            fields = try MiniYAML.parse(yaml.joined(separator: "\n"))
        } catch let error as MiniYAML.ParseError {
            throw SkillError(message: "frontmatter 无法解析：\(error.message)")
        }
        do {
            var name = singleLine(try fields["name"]?.stringValue(field: "name") ?? "")
            if name.isEmpty { name = singleLine(defaultName) }
            guard !name.isEmpty else { throw SkillError(message: "缺少 name") }
            guard name.count <= maxNameLength else { throw SkillError(message: "name 不能超过 \(maxNameLength) 个字符") }
            let description = singleLine(try fields["description"]?.stringValue(field: "description") ?? "")
            guard !description.isEmpty else { throw SkillError(message: "缺少 description") }
            let short = try fields["metadata"]?["short-description"]?.stringValue(field: "metadata.short-description").map(singleLine)
            return Frontmatter(name: name, description: description, shortDescription: short?.isEmpty == false ? short : nil)
        } catch let error as MiniYAML.ParseError {
            throw SkillError(message: error.message)
        }
    }

    /// `agents/openai.yaml` → `policy.allow_implicit_invocation`, default
    /// true. Unreadable metadata fails open, as in Codex.
    static func implicitInvocationAllowed(skillDirectory: String) -> Bool {
        let path = (skillDirectory as NSString).appendingPathComponent("agents/openai.yaml")
        guard let data = FileManager.default.contents(atPath: path),
              let yaml = try? MiniYAML.parse(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")) else {
            return true
        }
        return yaml["policy"]?["allow_implicit_invocation"]?.boolValue ?? true
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    /// Every `SKILL.md` below `root`, sorted, following symlinked folders
    /// (Codex follows them), skipping hidden folders, at most
    /// `maxScanDepth` levels deep.
    static func skillFiles(under root: String) -> [String] {
        var found: [String] = []
        var visited = Set<String>()
        var scanned = 0
        func walk(_ directory: String, depth: Int) {
            guard depth <= maxScanDepth, scanned < maxDirectoriesPerRoot,
                  visited.insert(PluginPath.real(directory)).inserted else { return }
            scanned += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() {
                let path = (directory as NSString).appendingPathComponent(name)
                if name == fileName {
                    var flag: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &flag), !flag.boolValue { found.append(path) }
                } else if !name.hasPrefix("."), isDirectory(path) {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return found.sorted()
    }

    // MARK: Prompt

    /// Paths `read_file` may open for these skills: each listed skill's
    /// folder, also by its real path when it sits behind a symlink.
    public var readableRoots: [String] {
        var roots: [String] = []
        for skill in skills where skill.allowsImplicitInvocation {
            for path in [skill.directory, PluginPath.real(skill.directory)] where !roots.contains(path) {
                roots.append(path)
            }
        }
        return roots
    }

    /// The model-visible list (Codex progressive disclosure): name,
    /// description and `SKILL.md` path of every skill, within `budget`.
    /// Over budget, descriptions are shortened evenly first, then dropped,
    /// then trailing skills are left out behind a 「还有 N 个技能未列出」 line.
    /// Nil when there is nothing to list.
    public func promptSection(budget: SkillPromptBudget = .characters(SkillPromptBudget.defaultCharacters)) -> String? {
        let offered = skills.filter(\.allowsImplicitInvocation)
        guard !offered.isEmpty else { return nil }
        let lines = Self.renderLines(offered, budget: budget)
        return """
        ## 技能
        下面每个技能是一份 SKILL.md 说明。用户的请求与某个技能的描述相符时，先用 read_file 读取它的 SKILL.md，再按里面的步骤做；只读相关的技能，不要预先全部读取。SKILL.md 里的相对路径以它所在的文件夹为准。
        \(lines.joined(separator: "\n"))
        """
    }

    static func omissionLine(_ count: Int) -> String {
        "- 还有 \(count) 个技能未列出（技能列表超出长度上限）。"
    }

    static func renderLines(_ skills: [Skill], budget: SkillPromptBudget) -> [String] {
        let entries = skills.map { skill -> (name: String, description: [Character], path: String) in
            var description = Array(skill.description)
            if description.count > maxDescriptionCharacters {
                description = Array(description.prefix(maxDescriptionCharacters)) + Array("...")
            }
            return (skill.name, description, skill.path)
        }
        func line(_ index: Int, descriptionCharacters: Int) -> String {
            let entry = entries[index]
            let description = String(entry.description.prefix(descriptionCharacters))
            return description.isEmpty
                ? "- \(entry.name): (file: \(entry.path))"
                : "- \(entry.name): \(description) (file: \(entry.path))"
        }
        let limit = budget.limit
        let full = entries.indices.map { line($0, descriptionCharacters: entries[$0].description.count) }
        if full.reduce(0, { $0 + budget.cost($1) }) <= limit { return full }

        let minimum = entries.indices.map { line($0, descriptionCharacters: 0) }
        let minimumCost = minimum.reduce(0) { $0 + budget.cost($1) }
        if minimumCost <= limit {
            // Hand out description characters round-robin so no skill
            // monopolises what is left. A description of k characters adds
            // them plus one space to the bare line.
            let byteOffsets = entries.map { entry in
                entry.description.reduce(into: [0]) { sums, character in sums.append(sums.last! + character.utf8.count) }
            }
            func cost(_ index: Int, _ characters: Int) -> Int {
                guard characters > 0 else { return budget.cost(minimum[index]) }
                switch budget {
                case .characters:
                    return minimum[index].count + characters + 1 + 1
                case .tokens:
                    return (minimum[index].utf8.count + byteOffsets[index][characters] + 1 + 1 + 3) / 4
                }
            }
            var allocation = [Int](repeating: 0, count: entries.count)
            var used = minimumCost
            var changed = true
            while changed {
                changed = false
                for index in entries.indices where allocation[index] < entries[index].description.count {
                    let delta = cost(index, allocation[index] + 1) - cost(index, allocation[index])
                    guard used + delta <= limit else { continue }
                    used += delta
                    allocation[index] += 1
                    changed = true
                }
            }
            return entries.indices.map { line($0, descriptionCharacters: allocation[$0]) }
        }

        // Not even every name fits: keep leading skills without
        // descriptions and say how many were left out.
        var kept: [String] = []
        var used = 0
        for candidate in minimum {
            let cost = budget.cost(candidate)
            guard used + cost <= limit else { break }
            kept.append(candidate)
            used += cost
        }
        while !kept.isEmpty, used + budget.cost(omissionLine(entries.count - kept.count)) > limit {
            used -= budget.cost(kept.removeLast())
        }
        return kept + [omissionLine(entries.count - kept.count)]
    }
}
