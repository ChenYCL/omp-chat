import CryptoKit
import Foundation

/// Where an installed plugin came from.
public enum PluginSource: Codable, Equatable, Sendable {
    case folder(path: String)
    case git(url: String, ref: String?, subdirectory: String?, commit: String)
    /// Found in the plugins folder without an install record.
    case unknown

    public var summary: String {
        switch self {
        case .folder(let path):
            return "文件夹 \(path)"
        case .git(let url, let ref, let subdirectory, let commit):
            var text = "git \(url)"
            if let ref { text += " @ \(ref)" }
            if let subdirectory { text += " · \(subdirectory)" }
            return text + " · \(commit.prefix(12))"
        case .unknown:
            return "来源未知"
        }
    }
}

/// What a plugin bundles, read from its files.
public struct PluginContents: Equatable, Sendable {
    public var skills: [Skill] = []
    public var skillProblems: [SkillProblem] = []
    /// Every bundled server; `enabled` is the per-server switch.
    public var mcpServers: [MCPServerConfig] = []
    /// Servers that could not be read: 「名字：原因」.
    public var mcpProblems: [String] = []
    public var hooks: [HookDefinition] = []
    /// Manifest and hooks-file warnings.
    public var warnings: [String] = []

    /// Hash of every hook definition. Trust is recorded against it, so a
    /// changed hook needs to be trusted again (Codex does the same).
    public var hooksFingerprint: String? {
        guard !hooks.isEmpty else { return nil }
        let canonical = hooks.map { hook in
            [hook.source, hook.event.rawValue, hook.matcher ?? "", hook.handler.type, hook.handler.command ?? "",
             String(hook.handler.timeout), hook.handler.isAsync ? "1" : "0"].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct InstalledPlugin: Identifiable, Equatable, Sendable {
    /// The manifest name; also the folder name under `plugins/`.
    public var id: String
    public var root: String
    /// `PLUGIN_DATA`.
    public var dataDirectory: String
    /// Nil when the plugin cannot be loaded; `problem` says why.
    public var manifest: PluginManifest?
    public var problem: String?
    public var enabled: Bool
    public var source: PluginSource
    public var installedAt: Date?
    public var contents: PluginContents
    /// The user trusted the current hook definitions.
    public var hooksTrusted: Bool

    public var displayName: String { manifest?.displayName ?? id }
    /// Whether its skills, servers and hooks are in use.
    public var isActive: Bool { enabled && problem == nil }

    /// What an active plugin contributes; empty while it is off or broken.
    public var activeMCPServers: [MCPServerConfig] { isActive ? contents.mcpServers : [] }

    public var activeSkillRoots: [SkillRoot] {
        guard isActive else { return [] }
        return PluginStore.skillRootPaths(manifest: manifest, root: root).map { SkillRoot(path: $0, scope: .plugin(id)) }
    }

    /// Runnable hooks, only once the user trusted the current definitions.
    public var activeHooks: [PluginHook] {
        guard isActive, hooksTrusted else { return [] }
        return contents.hooks.filter(\.runs).map { PluginHook(definition: $0, pluginRoot: root, pluginData: dataDirectory) }
    }

    public var activeReadableRoots: [String] {
        guard isActive else { return [] }
        let real = PluginPath.real(root)
        return real == root ? [root] : [root, real]
    }
}

/// A staged install waiting for the user's confirmation. Nothing is
/// installed until `PluginStore.commitInstall` runs.
public struct PluginInstallPlan: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Removed by commit or discard.
    public var stagingDirectory: String
    /// The staged plugin root.
    public var pluginDirectory: String
    public var manifest: PluginManifest
    public var source: PluginSource
    /// Read from the staged copy, with paths as they will be once installed.
    public var contents: PluginContents
    /// Version of the copy this replaces; `.some(nil)` when the installed
    /// copy has no version, nil when nothing is replaced.
    public var replacing: String??

    /// Command lines of the hooks that can run here, each with its event and
    /// matcher. Hooks this app never fires are listed in `contents` only.
    public var hookCommands: [String] {
        contents.hooks.filter(\.runs).map { hook in
            let matcher = hook.matcher.map { "（\($0)）" } ?? ""
            return "\(hook.event.rawValue)\(matcher)：\(hook.handler.command ?? "")"
        }
    }

    /// What each enabled MCP server starts: its command line, or its URL.
    public var mcpCommands: [String] {
        contents.mcpServers.filter(\.enabled).map { server in
            if let command = server.command {
                let line = ([command] + server.args).map(Self.display).joined(separator: " ")
                return "\(server.name)：\(line)" + (server.cwd.map { "（工作目录 \($0)）" } ?? "")
            }
            return "\(server.name)：\(server.url ?? "")"
        }
    }

    private static func display(_ argument: String) -> String {
        argument.contains(" ") || argument.isEmpty ? "\"\(argument)\"" : argument
    }
}

public enum PluginStoreError: Error, Equatable, LocalizedError {
    case notADirectory(String)
    case escapes(String)
    case manifest(String)
    case badGitURL
    case gitMissing
    case git(String)
    case badSubdirectory
    case notInstalled(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "「\(path)」不是文件夹"
        case .escapes(let detail): "插件的文件指向插件目录以外，拒绝安装：\(detail)"
        case .manifest(let detail): detail
        case .badGitURL: "git 地址不可用"
        case .gitMissing: "这台 Mac 上没有可用的 git"
        case .git(let detail): "git 失败：\(detail)"
        case .badSubdirectory: "子目录必须是仓库里的相对路径，且不能含 .."
        case .notInstalled(let id): "没有安装插件「\(id)」"
        case .io(let detail): detail
        }
    }
}

/// Installed Codex plugins, kept under `root`:
///
/// - `plugins/<name>/` — each plugin's files
/// - `data/<name>/` — each plugin's writable `PLUGIN_DATA`
/// - `staging/` — installs awaiting confirmation
/// - `plugins.json` — enabled switches, sources, hook trust
///
/// The store never starts anything: MCP servers are handed to the MCP
/// manager, hooks to `HookRunner`.
public final class PluginStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    /// `<app support>/OMPChat/Plugins`, honouring `OMPCHAT_STORE_DIR`.
    public static func defaultRoot() -> URL {
        FileConversationStore.defaultDirectory().appendingPathComponent("Plugins", isDirectory: true)
    }

    var pluginsDirectory: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var stateURL: URL { root.appendingPathComponent("plugins.json") }

    // MARK: Listing

    public func installed() -> [InstalledPlugin] {
        let state = lock.withLock { readState() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let path = pluginsDirectory.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return describe(id: name, root: path, entry: state.plugins[name])
        }
    }

    public func plugin(id: String) -> InstalledPlugin? {
        installed().first { $0.id == id }
    }

    private func describe(id: String, root: String, entry: StateEntry?) -> InstalledPlugin {
        let data = dataDirectory.appendingPathComponent(id).path
        var plugin = InstalledPlugin(
            id: id, root: root, dataDirectory: data, manifest: nil, problem: nil,
            enabled: entry?.enabled ?? false, source: entry?.source ?? .unknown,
            installedAt: entry?.installedAt, contents: PluginContents(), hooksTrusted: false
        )
        do {
            try Self.checkContainment(root: root)
            let manifest = try Self.loadManifest(root: root)
            plugin.manifest = manifest
            if manifest.name != id {
                plugin.problem = "清单里的名字「\(manifest.name)」和文件夹「\(id)」不一致"
            }
            plugin.contents = Self.inspect(manifest: manifest, root: root, dataDirectory: data, disabledServers: Set(entry?.disabledMCPServers ?? []))
            plugin.hooksTrusted = plugin.contents.hooksFingerprint != nil && plugin.contents.hooksFingerprint == entry?.trustedHooks
        } catch {
            plugin.problem = error.localizedDescription
        }
        return plugin
    }

    // MARK: What active plugins contribute

    /// Bundled servers of enabled plugins, for the MCP manager to merge.
    /// Ids are `<plugin>-<server>` so two plugins cannot collide; origin is
    /// `plugin:<id>`.
    public func mcpServers() -> [MCPServerConfig] {
        installed().flatMap(\.activeMCPServers)
    }

    /// Skill folders of enabled plugins, in plugin order.
    public func skillRoots() -> [SkillRoot] {
        installed().flatMap(\.activeSkillRoots)
    }

    /// Hooks of enabled plugins whose hooks the user trusted. Creates each
    /// plugin's data folder, which hook commands may write to.
    public func activeHooks() -> [PluginHook] {
        let hooks = installed().flatMap(\.activeHooks)
        for folder in Set(hooks.map(\.pluginData)) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        return hooks
    }

    /// Folders `read_file` may read without leaving the read risk class.
    public func readableRoots() -> [String] {
        installed().flatMap(\.activeReadableRoots)
    }

    // MARK: Switches

    public func setEnabled(_ enabled: Bool, id: String) throws {
        try update(id: id) { $0.enabled = enabled }
    }

    /// Trusts the plugin's current hook definitions, or withdraws trust.
    public func setHooksTrusted(_ trusted: Bool, id: String) throws {
        guard let plugin = plugin(id: id) else { throw PluginStoreError.notInstalled(id) }
        let fingerprint = plugin.contents.hooksFingerprint
        try update(id: id) { $0.trustedHooks = trusted ? fingerprint : nil }
    }

    /// Codex's `plugins.<plugin>.mcp_servers.<server>.enabled`. `server` is
    /// the name in the plugin's MCP config.
    public func setMCPServerEnabled(_ enabled: Bool, server: String, pluginID: String) throws {
        try update(id: pluginID) { entry in
            entry.disabledMCPServers.removeAll { $0 == server }
            if !enabled { entry.disabledMCPServers.append(server) }
        }
    }

    public func uninstall(id: String) throws {
        let path = pluginsDirectory.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: path.path) else { throw PluginStoreError.notInstalled(id) }
        do {
            try FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(id))
        } catch {
            throw PluginStoreError.io("卸载失败：\(error.localizedDescription)")
        }
        try lock.withLock {
            var state = readState()
            state.plugins.removeValue(forKey: id)
            try writeState(state)
        }
    }

    private func update(id: String, _ change: (inout StateEntry) -> Void) throws {
        guard FileManager.default.fileExists(atPath: pluginsDirectory.appendingPathComponent(id).path) else {
            throw PluginStoreError.notInstalled(id)
        }
        try lock.withLock {
            var state = readState()
            var entry = state.plugins[id] ?? StateEntry(enabled: false, source: .unknown, installedAt: nil)
            change(&entry)
            state.plugins[id] = entry
            try writeState(state)
        }
    }

    // MARK: Installing

    /// Copies `folder` into staging and reads it. Nothing is installed yet.
    public func prepareInstall(folder: String) throws -> PluginInstallPlan {
        let source = PluginPath.real(folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginStoreError.notADirectory(folder)
        }
        let container = try makeStagingContainer()
        let staged = (container as NSString).appendingPathComponent("plugin")
        do {
            try FileManager.default.copyItem(atPath: source, toPath: staged)
            // A checkout's history is not part of the plugin.
            try? FileManager.default.removeItem(atPath: (staged as NSString).appendingPathComponent(".git"))
            return try plan(container: container, pluginDirectory: staged, source: .folder(path: folder))
        } catch {
            try? FileManager.default.removeItem(atPath: container)
            if let error = error as? PluginStoreError { throw error }
            throw PluginStoreError.io("复制插件失败：\(error.localizedDescription)")
        }
    }

    /// Shallow-clones `url` (at `ref` when given) into staging, records the
    /// commit, and reads the plugin at the repository root or at
    /// `subdirectory`. Nothing is installed yet.
    public func prepareInstall(gitURL url: String, ref: String? = nil, subdirectory: String? = nil, runner: PluginCommandRunner) async throws -> PluginInstallPlan {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAcceptableGitURL(url) else { throw PluginStoreError.badGitURL }
        let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let ref, ref.hasPrefix("-") || ref.contains(where: \.isWhitespace) { throw PluginStoreError.badGitURL }
        let subdirectory = subdirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).nilIfEmpty
        if let subdirectory, subdirectory.split(separator: "/").contains("..") || subdirectory.hasPrefix("~") {
            throw PluginStoreError.badSubdirectory
        }
        guard let git = GitBinary.resolve() else { throw PluginStoreError.gitMissing }

        let container = try makeStagingContainer()
        do {
            let checkout = (container as NSString).appendingPathComponent("checkout")
            var clone = [git, "clone", "--depth", "1"]
            if let ref { clone += ["--branch", ref] }
            clone += ["--", url, checkout]
            let environment = ["GIT_TERMINAL_PROMPT": "0"]
            let cloned = await runner(PluginCommand(
                command: clone.map(PluginCommand.shellQuoted).joined(separator: " "),
                cwd: container, timeout: 180, environment: environment
            ))
            guard cloned.launchError == nil, !cloned.timedOut, cloned.exitCode == 0 else {
                throw PluginStoreError.git(Self.failureText(cloned))
            }
            let head = await runner(PluginCommand(
                command: [git, "-C", checkout, "rev-parse", "HEAD"].map(PluginCommand.shellQuoted).joined(separator: " "),
                cwd: container, timeout: 30, environment: environment
            ))
            let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.exitCode == 0, !commit.isEmpty else { throw PluginStoreError.git(Self.failureText(head)) }
            try? FileManager.default.removeItem(atPath: (checkout as NSString).appendingPathComponent(".git"))

            var pluginDirectory = checkout
            if let subdirectory {
                pluginDirectory = (checkout as NSString).appendingPathComponent(subdirectory)
                var isDirectory: ObjCBool = false
                guard PluginPath.isInside(pluginDirectory, root: checkout),
                      FileManager.default.fileExists(atPath: pluginDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw PluginStoreError.badSubdirectory
                }
            }
            return try plan(
                container: container, pluginDirectory: pluginDirectory,
                source: .git(url: url, ref: ref, subdirectory: subdirectory, commit: commit)
            )
        } catch {
            try? FileManager.default.removeItem(atPath: container)
            throw error
        }
    }

    /// Moves a confirmed plan into `plugins/`, replacing an older copy.
    /// A new plugin starts enabled with its hooks untrusted; a replaced one
    /// keeps its switches, and its hook trust only if the hooks are unchanged.
    @discardableResult
    public func commitInstall(_ plan: PluginInstallPlan) throws -> InstalledPlugin {
        let id = plan.manifest.name
        let destination = pluginsDirectory.appendingPathComponent(id)
        do {
            try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(atPath: plan.pluginDirectory, toPath: destination.path)
        } catch {
            throw PluginStoreError.io("安装失败：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(atPath: plan.stagingDirectory)
        try lock.withLock {
            var state = readState()
            var entry = state.plugins[id] ?? StateEntry(enabled: true, source: plan.source, installedAt: nil)
            entry.source = plan.source
            entry.installedAt = Date()
            state.plugins[id] = entry
            try writeState(state)
        }
        guard let installed = plugin(id: id) else { throw PluginStoreError.notInstalled(id) }
        return installed
    }

    public func discardInstall(_ plan: PluginInstallPlan) {
        try? FileManager.default.removeItem(atPath: plan.stagingDirectory)
    }

    private func makeStagingContainer() throws -> String {
        let container = stagingDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            throw PluginStoreError.io("无法创建临时目录：\(error.localizedDescription)")
        }
        return container.path
    }

    private func plan(container: String, pluginDirectory: String, source: PluginSource) throws -> PluginInstallPlan {
        try Self.checkContainment(root: pluginDirectory)
        let manifest = try Self.loadManifest(root: pluginDirectory)
        if !manifest.escapingPaths.isEmpty {
            throw PluginStoreError.escapes("清单里的路径 \(manifest.escapingPaths.joined(separator: "、"))")
        }
        let id = manifest.name
        let finalRoot = pluginsDirectory.appendingPathComponent(id).path
        let existing = plugin(id: id)
        let contents = Self.inspect(
            manifest: manifest, root: pluginDirectory, dataDirectory: dataDirectory.appendingPathComponent(id).path,
            disabledServers: [], installedRoot: finalRoot
        )
        return PluginInstallPlan(
            id: UUID(), stagingDirectory: container, pluginDirectory: pluginDirectory,
            manifest: manifest, source: source, contents: contents,
            replacing: existing.map { $0.manifest?.version }
        )
    }

    // MARK: Reading a plugin

    static func loadManifest(root: String) throws -> PluginManifest {
        do {
            return try PluginManifest.load(pluginRoot: root)
        } catch {
            throw PluginStoreError.manifest(error.localizedDescription)
        }
    }

    /// Refuses a tree with a symlink that is absolute (it would point back
    /// at the source after the copy) or that resolves outside `root`.
    static func checkContainment(root: String) throws {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let relative = relativePath(url.path, root: base.path)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                throw PluginStoreError.escapes("无法读取符号链接 \(relative)")
            }
            if target.hasPrefix("/") || target.hasPrefix("~") {
                throw PluginStoreError.escapes("符号链接 \(relative) → \(target) 是绝对路径")
            }
            let resolved = ((url.deletingLastPathComponent().path as NSString).appendingPathComponent(target) as NSString).standardizingPath
            guard PluginPath.isInside(resolved, root: root) else {
                throw PluginStoreError.escapes("符号链接 \(relative) → \(target)")
            }
        }
    }

    static func skillRootPaths(manifest: PluginManifest?, root: String) -> [String] {
        if let manifest, !manifest.skills.isEmpty { return manifest.skills }
        let fallback = (root as NSString).appendingPathComponent(PluginManifest.defaultSkillsDirectory)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fallback, isDirectory: &isDirectory) && isDirectory.boolValue ? [fallback] : []
    }

    /// Reads skills, MCP servers and hooks. `installedRoot` is where the
    /// plugin will live, for `${PLUGIN_ROOT}` in server commands; it
    /// defaults to `root`.
    static func inspect(manifest: PluginManifest, root: String, dataDirectory: String, disabledServers: Set<String>, installedRoot: String? = nil) -> PluginContents {
        var contents = PluginContents()
        contents.warnings = manifest.warnings
        let finalRoot = installedRoot ?? root

        let catalog = SkillCatalog.load(roots: skillRootPaths(manifest: manifest, root: root).map { SkillRoot(path: $0, scope: .plugin(manifest.name)) })
        contents.skills = catalog.skills
        contents.skillProblems = catalog.problems
            + catalog.shadowed.map { SkillProblem(path: $0.path, reason: "和另一个技能同名「\($0.name)」，未使用") }

        let mcpData: Data?
        switch manifest.mcpServers {
        case .file(let path)?:
            mcpData = FileManager.default.contents(atPath: path)
            if mcpData == nil { contents.warnings.append("找不到 MCP 配置 \(relativePath(path, root: root))") }
        case .inline(let data)?:
            mcpData = data
        case nil:
            mcpData = FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(PluginManifest.defaultMCPConfig))
        }
        if let mcpData {
            do {
                let parsed = try MCPServerConfig.parse(mcpData, origin: "plugin:\(manifest.name)")
                contents.mcpProblems = parsed.skipped.map { "\($0.name)：\($0.reason)" }
                for server in parsed.servers {
                    switch pluginServer(server, pluginID: manifest.name, root: finalRoot, dataDirectory: dataDirectory, disabled: disabledServers) {
                    case .success(let configured): contents.mcpServers.append(configured)
                    case .failure(let problem): contents.mcpProblems.append("\(server.name)：\(problem.reason)")
                    }
                }
            } catch MCPServerConfig.ParseError.noServers {
                // An empty server map bundles nothing.
            } catch {
                contents.warnings.append("MCP 配置不是合法的 JSON 对象，未载入")
            }
        }

        let hookSources: [(source: String, object: [String: Any]?)]
        switch manifest.hooks {
        case .files(let paths)?:
            hookSources = paths.map { path in
                (relativePath(path, root: root), FileManager.default.contents(atPath: path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
            }
        case .inline(let objects)?:
            hookSources = objects.enumerated().map { index, data in
                ("plugin.json#hooks[\(index)]", (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            }
        case nil:
            let path = (root as NSString).appendingPathComponent(PluginManifest.defaultHooksFile)
            hookSources = FileManager.default.fileExists(atPath: path)
                ? [(PluginManifest.defaultHooksFile, FileManager.default.contents(atPath: path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })]
                : []
        }
        for (source, object) in hookSources {
            guard let object else {
                contents.warnings.append("\(source)：不是合法的钩子 JSON 对象，未载入")
                continue
            }
            do {
                let parsed = try HooksFile.parse(object: object, pluginID: manifest.name, source: source)
                contents.hooks += parsed.hooks
                contents.warnings += parsed.warnings
            } catch {
                contents.warnings.append("\(source)：\(error.localizedDescription)，未载入")
            }
        }
        return contents
    }

    struct ServerProblem: Error {
        var reason: String
    }

    /// A plugin server as the MCP manager runs it: a collision-free id,
    /// `${PLUGIN_ROOT}` / `${PLUGIN_DATA}` (and the `CLAUDE_` spellings)
    /// expanded in the command line, the same variables in its environment,
    /// and a relative `cwd` resolved against the plugin root, which it must
    /// not leave (Codex's rule for plugin servers).
    static func pluginServer(_ server: MCPServerConfig, pluginID: String, root: String, dataDirectory: String, disabled: Set<String>) -> Result<MCPServerConfig, ServerProblem> {
        guard let id = MCPServerConfig.sanitizedID("\(pluginID)-\(server.id)") else {
            return .failure(ServerProblem(reason: "名字里没有可用的字符"))
        }
        func expand(_ text: String) -> String {
            text.replacingOccurrences(of: "${PLUGIN_ROOT}", with: root)
                .replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root)
                .replacingOccurrences(of: "${PLUGIN_DATA}", with: dataDirectory)
                .replacingOccurrences(of: "${CLAUDE_PLUGIN_DATA}", with: dataDirectory)
        }
        var configured = server
        configured.id = id
        configured.command = server.command.map(expand)
        configured.args = server.args.map(expand)
        configured.url = server.url.map(expand)
        configured.env = server.env.mapValues(expand)
        if let cwd = server.cwd.map(expand)?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            if cwd.hasPrefix("/") {
                configured.cwd = cwd
            } else {
                let resolved = ((root as NSString).appendingPathComponent(cwd) as NSString).standardizingPath
                guard PluginPath.isInside(resolved, root: root) else {
                    return .failure(ServerProblem(reason: "cwd「\(cwd)」指向插件目录以外"))
                }
                configured.cwd = resolved
            }
        }
        if server.command != nil {
            for (key, value) in ["PLUGIN_ROOT": root, "PLUGIN_DATA": dataDirectory, "CLAUDE_PLUGIN_ROOT": root, "CLAUDE_PLUGIN_DATA": dataDirectory]
            where configured.env[key] == nil {
                configured.env[key] = value
            }
        }
        configured.enabled = server.enabled && !disabled.contains(server.name)
        configured.origin = "plugin:\(pluginID)"
        return .success(configured)
    }

    static func relativePath(_ path: String, root: String) -> String {
        let base = (root as NSString).standardizingPath
        let full = (path as NSString).standardizingPath
        if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
        // The same place spelled through a symlink (`/var` vs `/private/var`);
        // the last component stays unresolved, since it may be the link.
        let realBase = PluginPath.real(root)
        let realFull = (PluginPath.real((path as NSString).deletingLastPathComponent) as NSString)
            .appendingPathComponent((path as NSString).lastPathComponent)
        return realFull.hasPrefix(realBase + "/") ? String(realFull.dropFirst(realBase.count + 1)) : full
    }

    static func isAcceptableGitURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        for scheme in ["https://", "http://", "ssh://", "git://", "file://"] where url.lowercased().hasPrefix(scheme) {
            return url.count > scheme.count
        }
        // A local repository, or scp-like `user@host:path`.
        if url.hasPrefix("/") { return true }
        if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":"), url.index(after: colon) < url.endIndex {
            return at > url.startIndex
        }
        return false
    }

    private static func failureText(_ result: PluginCommandResult) -> String {
        if let launchError = result.launchError { return launchError }
        if result.timedOut { return "超时" }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.suffix(400)) }
        return "退出码 \(result.exitCode)"
    }

    // MARK: State

    private struct State: Codable {
        var plugins: [String: StateEntry] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            plugins = try container.decodeIfPresent([String: StateEntry].self, forKey: .plugins) ?? [:]
        }
    }

    private struct StateEntry: Codable {
        var enabled: Bool
        var source: PluginSource
        var installedAt: Date?
        /// Fingerprint of the hook definitions the user trusted.
        var trustedHooks: String?
        /// Server names switched off.
        var disabledMCPServers: [String] = []

        init(enabled: Bool, source: PluginSource, installedAt: Date?) {
            self.enabled = enabled
            self.source = source
            self.installedAt = installedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            source = (try? container.decodeIfPresent(PluginSource.self, forKey: .source)) ?? .unknown
            installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt)
            trustedHooks = try container.decodeIfPresent(String.self, forKey: .trustedHooks)
            disabledMCPServers = try container.decodeIfPresent([String].self, forKey: .disabledMCPServers) ?? []
        }
    }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            throw PluginStoreError.io("无法保存插件设置：\(error.localizedDescription)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
