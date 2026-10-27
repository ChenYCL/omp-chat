import Foundation

// MARK: - ExternalImport (从 Claude Code / Cursor 导入)

/// Import sources, mirroring the official onboarding's
/// `externalAgentImport.provider.*` (Claude Code, Cursor).
public enum ExternalImportProvider: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case cursor

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }
}

/// Importable categories, the official `externalAgentConfig.itemType.*`.
public enum ExternalImportItemKind: String, CaseIterable, Codable, Sendable {
    case instructions
    case settings
    case mcpServers
    case skills
    case agents
    case commands
    case hooks
    case memory
    case plugins
    case sessions
    case projects

    public var title: String {
        switch self {
        case .instructions: "指令"
        case .settings: "设置"
        case .mcpServers: "MCP 服务器"
        case .skills: "技能"
        case .agents: "子代理"
        case .commands: "命令"
        case .hooks: "钩子"
        case .memory: "记忆"
        case .plugins: "插件"
        case .sessions: "会话"
        case .projects: "项目"
        }
    }
}

/// What running one entry does. Internal to the import: the scan carries it
/// so `ExternalImportExecutor` can act without re-reading the source.
enum ExternalImportOperation: Equatable, Sendable {
    /// Append a fenced block to OMPChat's 全局自定义指令.
    case appendInstructions(sourceName: String, block: String)
    /// Write `AGENTS.md` into `projectRoot`; the caller refuses to overwrite.
    case writeAgentsMD(projectRoot: String, sourceName: String, body: String)
    /// Add one server; env values ride separately as secrets.
    case addMCPServer(MCPServerConfig)
    /// Copy a whole skill folder into the user skills root under `name`.
    case copySkill(sourceFolder: String, name: String)
    case importSession(ExternalImportSession)
    /// Sidebar grouping for imported sessions; reuses a same-name project.
    case createProjectGroup(name: String)
    /// Stage+commit a Claude Code plugin folder through the model's plugin store.
    case installPlugin(folder: String, name: String)
}

/// One parsed chat to import. `key` lands in `Conversation.importedFrom`
/// so a re-import skips it.
public struct ExternalImportSession: Equatable, Sendable {
    public var key: String
    public var title: String
    /// Folder the chat worked in; nil keeps the thread unbound.
    public var workingDirectory: String?
    /// Project folder name for the sidebar grouping, when bound.
    public var projectFolderName: String?
    public var messages: [ExternalImportMessage]
    public var createdAt: Date?
    public var updatedAt: Date?
    /// First prompt, for the collapsed preview.
    public var preview: String

    public init(key: String, title: String, workingDirectory: String?, messages: [ExternalImportMessage], createdAt: Date?, updatedAt: Date?) {
        self.key = key
        self.title = title
        self.workingDirectory = workingDirectory
        self.projectFolderName = workingDirectory.map { ($0 as NSString).lastPathComponent }
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = messages.first(where: { $0.role == "user" })?.text.prefix(160).description ?? ""
    }
}

public struct ExternalImportMessage: Equatable, Sendable {
    /// "user" or "assistant".
    public var role: String
    public var text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// One selectable row in the import UI.
public struct ExternalImportEntry: Identifiable, Equatable, Sendable {
    /// `provider.kind` or `provider.kind.name` for per-item rows.
    public var id: String
    public var provider: ExternalImportProvider
    public var kind: ExternalImportItemKind
    /// Row text, e.g. 「技能 (48)」 or a skill's name.
    public var title: String
    /// What will happen; secrets redacted.
    public var detail: String
    public var count: Int
    /// Not nil when the row is shown but cannot be imported, and why.
    public var skippedReason: String?
    /// Official tooltip wording where one exists.
    public var tooltip: String?
    var operation: ExternalImportOperation?

    public var isAvailable: Bool { skippedReason == nil && operation != nil }
}

/// One run of the scanner.
public struct ExternalImportScan: Equatable, Sendable, Identifiable {
    public var providersFound: [ExternalImportProvider]
    public var entries: [ExternalImportEntry]
    /// Categories OMPChat cannot honestly use, with the reason. Shown, never selectable.
    public var notImported: [NotImported]

    /// The empty result iOS reports: the scanned files live on the Mac only.
    public static let empty = ExternalImportScan(providersFound: [], entries: [], notImported: [])

    /// Sheet presentation needs an identity; a scan is its own value.
    public var id: String { "\(providersFound.map(\.rawValue).joined(separator: ","))|\(entries.map(\.id).joined(separator: ","))" }

    public struct NotImported: Identifiable, Equatable, Sendable {
        public var id: String
        public var provider: ExternalImportProvider
        public var kind: ExternalImportItemKind
        public var reason: String
    }

    public var isEmpty: Bool {
        providersFound.isEmpty || !entries.contains(where: \.isAvailable)
    }

    public func entries(provider: ExternalImportProvider) -> [ExternalImportEntry] {
        entries.filter { $0.provider == provider }
    }

    /// Groups per-item rows under their kind, scan order preserved.
    public struct Group: Identifiable {
        public var id: String
        public var kind: ExternalImportItemKind
        public var rows: [ExternalImportEntry]
    }

    public func groups(provider: ExternalImportProvider) -> [Group] {
        var order: [ExternalImportItemKind] = []
        var byKind: [ExternalImportItemKind: [ExternalImportEntry]] = [:]
        for entry in entries(provider: provider) {
            if byKind[entry.kind] == nil { order.append(entry.kind) }
            byKind[entry.kind, default: []].append(entry)
        }
        return order.map { Group(id: "\(provider.rawValue).\($0.rawValue)", kind: $0, rows: byKind[$0] ?? []) }
    }
}

/// Which entry ids the user turned on. Built from a scan; constructible from
/// raw ids so `/debug/action` can drive an import without view state.
public struct ExternalImportSelection: Equatable, Sendable {
    public var enabledEntryIDs: Set<String>

    public init(enabledEntryIDs: Set<String>) {
        self.enabledEntryIDs = enabledEntryIDs
    }

    /// Everything currently importable (skipped rows stay off).
    public init(allOf scan: ExternalImportScan) {
        self.enabledEntryIDs = Set(scan.entries.filter(\.isAvailable).map(\.id))
    }

    public func contains(_ entry: ExternalImportEntry) -> Bool {
        enabledEntryIDs.contains(entry.id)
    }
}

public struct ExternalImportReport: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public var id: String
        public var provider: ExternalImportProvider
        public var kind: ExternalImportItemKind
        public var title: String
        /// nil = imported; else why it was skipped or what failed.
        public var note: String?
        public var failed: Bool

        public init(id: String, provider: ExternalImportProvider, kind: ExternalImportItemKind, title: String, note: String?, failed: Bool) {
            self.id = id
            self.provider = provider
            self.kind = kind
            self.title = title
            self.note = note
            self.failed = failed
        }
    }

    public var lines: [Line]
    public var importedCount: Int { lines.filter { $0.note == nil }.count }
    public var failedCount: Int { lines.filter(\.failed).count }
    public var skippedCount: Int { lines.count - importedCount - failedCount }
    public var errorSummary: String? { failedCount > 0 ? "导入未能完成。请重试，或暂时跳过。" : nil }

    public init(lines: [Line] = []) {
        self.lines = lines
    }

    public static func == (lhs: ExternalImportReport, rhs: ExternalImportReport) -> Bool {
        lhs.lines.count == rhs.lines.count && zip(lhs.lines, rhs.lines).allSatisfy {
            $0.id == $1.id && $0.note == $1.note && $0.failed == $1.failed
        }
    }
}
