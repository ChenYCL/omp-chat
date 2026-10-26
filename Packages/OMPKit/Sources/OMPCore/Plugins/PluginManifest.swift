import Foundation

/// A Codex plugin's `.codex-plugin/plugin.json`
/// (developers.openai.com/codex/plugins/build).
///
/// Unknown keys are ignored. A known key with the wrong type is an error, as
/// in Codex, whose serde types reject it. A component path that breaks the
/// path rules is dropped with a warning (Codex skips it too), except that a
/// path climbing out of the plugin (`..`, absolute) is recorded in
/// `escapingPaths`, and the store refuses to install such a plugin.
public struct PluginManifest: Equatable, Sendable {
    /// Where Codex looks first.
    public static let manifestPath = ".codex-plugin/plugin.json"
    /// The Claude Code location Codex also discovers.
    public static let legacyManifestPath = ".claude-plugin/plugin.json"
    /// Defaults used when the manifest does not name a component.
    public static let defaultSkillsDirectory = "skills"
    public static let defaultMCPConfig = ".mcp.json"
    public static let defaultHooksFile = "hooks/hooks.json"

    public struct Author: Equatable, Sendable {
        public var name: String?
        public var email: String?
        public var url: String?
    }

    /// Install-surface copy (`interface`).
    public struct Interface: Equatable, Sendable {
        public var displayName: String?
        public var shortDescription: String?
        public var longDescription: String?
        public var developerName: String?
        public var category: String?
        public var capabilities: [String] = []
        public var websiteURL: String?
        public var privacyPolicyURL: String?
        public var termsOfServiceURL: String?
        /// Starter prompts: at most 3, each at most 128 characters.
        public var defaultPrompts: [String] = []
        public var brandColor: String?
        /// Absolute paths inside the plugin.
        public var composerIcon: String?
        public var logo: String?
        public var logoDark: String?
        public var screenshots: [String] = []
    }

    public enum MCPServers: Equatable, Sendable {
        /// An absolute path inside the plugin.
        case file(String)
        /// The servers written straight into the manifest, as JSON.
        case inline(Data)
    }

    public enum Hooks: Equatable, Sendable {
        /// Absolute paths inside the plugin.
        case files([String])
        /// Hooks objects written straight into the manifest, as JSON.
        case inline([Data])
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case missing
        case notJSON
        case notObject
        case wrongType(field: String, expected: String)
        case invalidName(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                "没有找到插件清单：需要 \(PluginManifest.manifestPath)"
            case .notJSON:
                "plugin.json 不是合法的 JSON"
            case .notObject:
                "plugin.json 顶层必须是一个对象"
            case .wrongType(let field, let expected):
                "plugin.json 的「\(field)」必须是\(expected)"
            case .invalidName(let reason):
                "插件名不可用：\(reason)"
            }
        }
    }

    public var name: String
    public var version: String?
    public var description: String?
    public var author: Author?
    public var homepage: String?
    public var repository: String?
    public var license: String?
    public var keywords: [String]
    /// Absolute skill roots named by `skills`. Empty means the default
    /// `skills/` folder (which the manifest's own list replaces).
    public var skills: [String]
    public var mcpServers: MCPServers?
    public var apps: String?
    public var hooks: Hooks?
    public var interface: Interface?
    /// Fields that were left out and why, in Chinese, for the install sheet.
    public var warnings: [String]
    /// Component paths that point outside the plugin. Non-empty means the
    /// plugin must not be installed.
    public var escapingPaths: [String]

    public var displayName: String {
        let display = interface?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return display.isEmpty ? name : display
    }

    /// Finds the manifest under `pluginRoot` (`.codex-plugin/` first, then
    /// `.claude-plugin/`) and parses it.
    public static func load(pluginRoot: String) throws -> PluginManifest {
        for relative in [manifestPath, legacyManifestPath] {
            let path = (pluginRoot as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard let data = FileManager.default.contents(atPath: path) else { throw ParseError.notJSON }
            return try parse(data, pluginRoot: pluginRoot)
        }
        throw ParseError.missing
    }

    /// Parses manifest bytes. `pluginRoot` resolves component paths and
    /// supplies the name when the manifest leaves it empty.
    public static func parse(_ data: Data, pluginRoot: String) throws -> PluginManifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.notJSON
        }
        guard let json = object as? [String: Any] else { throw ParseError.notObject }
        var reader = Reader(json: json, root: pluginRoot)

        var name = try reader.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            name = (pluginRoot as NSString).lastPathComponent
        }
        if let problem = nameProblem(name) { throw ParseError.invalidName(problem) }

        var manifest = PluginManifest(
            name: name,
            version: try reader.string("version").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            description: try reader.string("description"),
            author: try reader.author(),
            homepage: try reader.string("homepage"),
            repository: try reader.string("repository"),
            license: try reader.string("license"),
            keywords: try reader.strings("keywords"),
            skills: reader.paths("skills"),
            mcpServers: reader.mcpServers(),
            apps: reader.singlePath("apps"),
            hooks: reader.hooks(),
            interface: try reader.interface(),
            warnings: [],
            escapingPaths: []
        )
        manifest.warnings = reader.warnings
        manifest.escapingPaths = reader.escapingPaths
        return manifest
    }

    /// Codex's plugin-name rule: ASCII letters, digits, `.`, `_` and `-`,
    /// with dots only between non-empty segments. Nil when `name` is fine.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "名字为空" }
        if name == "." || name == ".." || name.hasPrefix(".") || name.hasSuffix(".") || name.contains("..") {
            return "点号只能用在两段名字之间"
        }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                || scalar == "-" || scalar == "_" || scalar == "."
        }
        return allowed ? nil : "只能包含 ASCII 字母、数字、点、下划线和连字符"
    }
}

// MARK: - Reading

private struct Reader {
    let json: [String: Any]
    let root: String
    var warnings: [String] = []
    var escapingPaths: [String] = []

    init(json: [String: Any], root: String) {
        self.json = json
        self.root = root
    }

    func string(_ key: String, in object: [String: Any]? = nil, field: String? = nil) throws -> String? {
        let source = object ?? json
        guard let value = source[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw PluginManifest.ParseError.wrongType(field: field ?? key, expected: "字符串") }
        return text
    }

    func strings(_ key: String, in object: [String: Any]? = nil, field: String? = nil) throws -> [String] {
        let source = object ?? json
        guard let value = source[key], !(value is NSNull) else { return [] }
        guard let list = value as? [Any], let texts = list as? [String], texts.count == list.count else {
            throw PluginManifest.ParseError.wrongType(field: field ?? key, expected: "字符串数组")
        }
        return texts
    }

    func author() throws -> PluginManifest.Author? {
        guard let value = json["author"], !(value is NSNull) else { return nil }
        // Claude Code manifests may give the author as a bare string.
        if let name = value as? String { return PluginManifest.Author(name: name) }
        guard let object = value as? [String: Any] else {
            throw PluginManifest.ParseError.wrongType(field: "author", expected: "对象")
        }
        return PluginManifest.Author(
            name: try string("name", in: object, field: "author.name"),
            email: try string("email", in: object, field: "author.email"),
            url: try string("url", in: object, field: "author.url")
        )
    }

    /// `skills`: one path or a list of paths.
    mutating func paths(_ field: String) -> [String] {
        guard let value = json[field], !(value is NSNull) else { return [] }
        if let single = value as? String {
            return resolve(single, field: field).map { [$0] } ?? []
        }
        if let list = value as? [Any], let texts = list as? [String], texts.count == list.count {
            return texts.compactMap { resolve($0, field: field) }
        }
        warnings.append("「\(field)」应为路径或路径数组，已忽略")
        return []
    }

    mutating func singlePath(_ field: String) -> String? {
        guard let value = json[field], !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            warnings.append("「\(field)」应为路径，已忽略")
            return nil
        }
        return resolve(text, field: field)
    }

    mutating func mcpServers() -> PluginManifest.MCPServers? {
        guard let value = json["mcpServers"], !(value is NSNull) else { return nil }
        if let path = value as? String {
            return resolve(path, field: "mcpServers").map(PluginManifest.MCPServers.file)
        }
        if let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return .inline(data)
        }
        warnings.append("「mcpServers」应为路径或对象，已忽略")
        return nil
    }

    mutating func hooks() -> PluginManifest.Hooks? {
        guard let value = json["hooks"], !(value is NSNull) else { return nil }
        if let path = value as? String {
            return resolve(path, field: "hooks").map { .files([$0]) }
        }
        if let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return .inline([data])
        }
        if let list = value as? [Any] {
            if let texts = list as? [String], texts.count == list.count {
                let resolved = texts.compactMap { resolve($0, field: "hooks") }
                return resolved.isEmpty ? nil : .files(resolved)
            }
            if let objects = list as? [[String: Any]], objects.count == list.count {
                let encoded = objects.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                return encoded.isEmpty ? nil : .inline(encoded)
            }
        }
        warnings.append("「hooks」应为路径、路径数组、钩子对象或钩子对象数组，已忽略")
        return nil
    }

    mutating func interface() throws -> PluginManifest.Interface? {
        guard let value = json["interface"], !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw PluginManifest.ParseError.wrongType(field: "interface", expected: "对象")
        }
        func text(_ key: String, aliases: [String] = []) throws -> String? {
            for candidate in [key] + aliases {
                if let found = try string(candidate, in: object, field: "interface.\(candidate)") { return found }
            }
            return nil
        }
        var interface = PluginManifest.Interface(
            displayName: try text("displayName"),
            shortDescription: try text("shortDescription"),
            longDescription: try text("longDescription"),
            developerName: try text("developerName"),
            category: try text("category"),
            capabilities: try strings("capabilities", in: object, field: "interface.capabilities"),
            websiteURL: try text("websiteURL", aliases: ["websiteUrl"]),
            privacyPolicyURL: try text("privacyPolicyURL", aliases: ["privacyPolicyUrl"]),
            termsOfServiceURL: try text("termsOfServiceURL", aliases: ["termsOfServiceUrl"]),
            brandColor: try text("brandColor")
        )
        interface.defaultPrompts = defaultPrompts(object["defaultPrompt"])
        interface.composerIcon = asset(object["composerIcon"], field: "interface.composerIcon")
        interface.logo = asset(object["logo"], field: "interface.logo")
        interface.logoDark = asset(object["logoDark"], field: "interface.logoDark")
        if let shots = object["screenshots"] as? [Any] {
            interface.screenshots = shots.compactMap { asset($0, field: "interface.screenshots") }
        }
        return interface
    }

    /// `defaultPrompt`: a string or a list; at most 3 prompts of at most
    /// 128 characters, whitespace collapsed (Codex's limits).
    private mutating func defaultPrompts(_ value: Any?) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        let raw: [Any]
        if let single = value as? String {
            raw = [single]
        } else if let list = value as? [Any] {
            raw = list
        } else {
            warnings.append("「interface.defaultPrompt」应为字符串或字符串数组，已忽略")
            return []
        }
        var prompts: [String] = []
        for item in raw {
            guard prompts.count < 3 else {
                warnings.append("「interface.defaultPrompt」最多 3 条，多出的已忽略")
                break
            }
            guard let text = item as? String else { continue }
            let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if collapsed.isEmpty { continue }
            if collapsed.count > 128 {
                warnings.append("「interface.defaultPrompt」单条最多 128 个字符，过长的已忽略")
                continue
            }
            prompts.append(collapsed)
        }
        return prompts
    }

    private mutating func asset(_ value: Any?, field: String) -> String? {
        guard let text = value as? String else { return nil }
        return resolve(text, field: field)
    }

    /// Codex path rules: `./`-prefixed, relative to the plugin root, no `..`,
    /// staying inside the root.
    private mutating func resolve(_ raw: String, field: String) -> String? {
        switch PluginPath.resolve(raw, under: root) {
        case .inside(let path):
            return path
        case .notDotSlash:
            warnings.append("「\(field)」的路径「\(raw)」必须以 ./ 开头（相对插件根目录），已忽略")
            return nil
        case .escapes:
            escapingPaths.append(raw)
            warnings.append("「\(field)」的路径「\(raw)」指向插件目录以外")
            return nil
        }
    }
}

// MARK: - Paths

/// Path containment for plugin files. Containment is checked on real paths
/// (`realpath(3)`), so `/var` vs `/private/var` and symlinked folders cannot
/// fool it.
enum PluginPath {
    enum Resolution: Equatable {
        case inside(String)
        case notDotSlash
        case escapes
    }

    static func resolve(_ raw: String, under root: String) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return .escapes }
        guard trimmed.hasPrefix("./") else {
            return trimmed.split(separator: "/").contains("..") ? .escapes : .notDotSlash
        }
        let relative = String(trimmed.dropFirst(2))
        if relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return .escapes }
        let joined = ((root as NSString).appendingPathComponent(relative) as NSString).standardizingPath
        return isInside(joined, root: root) ? .inside(joined) : .escapes
    }

    /// Whether `path` is `root` or below it, after resolving symlinks in
    /// whatever part of each path exists.
    static func isInside(_ path: String, root: String) -> Bool {
        let base = real(root)
        let target = real(path)
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// `realpath` of the longest existing prefix, with the rest appended.
    static func real(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var head = standardized
        var tail: [String] = []
        while !head.isEmpty, head != "/" {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in tail.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return standardized
    }
}
