import Foundation

// The agent runtime's shared vocabulary. Everything that can be called by the
// model — built-in file and shell tools, MCP servers, plugin skills — is an
// `AgentToolProvider`, and every call is classified by `ToolRisk` so one
// approval policy covers them all.

/// What a tool call can do. Decides whether it needs the user's approval.
public enum ToolRisk: String, Codable, CaseIterable, Sendable {
    /// Reads inside the working directory (or a root the app registered, such
    /// as an installed skill). No side effects.
    case read
    /// Changes files.
    case write
    /// Runs commands, or reaches outside the working directory.
    case execute
    /// Drives the desktop or another app (computer use).
    case control

    /// What the risk means to the user, for approval cards and tool lists.
    public var title: String {
        switch self {
        case .read: "读取"
        case .write: "修改文件"
        case .execute: "运行命令"
        case .control: "控制电脑"
        }
    }
}

/// How freely the agent may act in a conversation.
public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    /// Reads only. Anything else is refused without asking.
    case readOnly
    /// Reads freely; every write, command and desktop action asks first.
    case ask
    /// Reads and file writes run on their own; commands and desktop actions ask.
    case auto
    /// Commands and file changes run on their own. Desktop control still asks.
    case full

    public var title: String {
        switch self {
        case .readOnly: "只读"
        case .ask: "每次询问"
        case .auto: "自动"
        case .full: "完全访问"
        }
    }
}

/// One function the model may call.
public struct AgentToolSpec: Hashable, Sendable {
    /// Wire name, unique across all providers, matching `^[a-zA-Z0-9_-]{1,64}$`
    /// (the OpenAI function-name rule, which gateways enforce).
    public var name: String
    public var description: String
    /// JSON Schema object, encoded as a string (same shape as `ToolSpec`).
    public var parametersJSON: String
    /// Static risk of the tool; a provider may refine it per call.
    public var risk: ToolRisk
    /// Where it comes from, for the approval card: "内置", "MCP · playwright",
    /// "技能 · deploy".
    public var source: String

    public init(name: String, description: String, parametersJSON: String, risk: ToolRisk, source: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.risk = risk
        self.source = source
    }

    /// The wire form sent to the model.
    public var wireSpec: ToolSpec {
        ToolSpec(name: name, description: description, parametersJSON: parametersJSON)
    }
}

/// What a tool call knows about where it runs.
public struct AgentToolContext: Sendable, Equatable {
    public var conversationID: UUID
    /// The thread's bound folder; nil for an unbound chat.
    public var workingDirectory: String?
    /// Extra folders a `read` may touch without leaving the "read" risk class,
    /// e.g. installed plugin and skill directories.
    public var readableRoots: [String]

    public init(conversationID: UUID, workingDirectory: String?, readableRoots: [String] = []) {
        self.conversationID = conversationID
        self.workingDirectory = workingDirectory
        self.readableRoots = readableRoots
    }
}

public struct AgentToolImage: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// What a tool call produced.
public struct AgentToolOutput: Sendable, Equatable {
    public var text: String
    /// True when the tool ran and reported failure (a non-zero exit, an MCP
    /// `isError`). A tool that could not run at all throws instead.
    public var isError: Bool
    /// Screenshots and other images the tool returned.
    public var images: [AgentToolImage]

    public init(text: String, isError: Bool = false, images: [AgentToolImage] = []) {
        self.text = text
        self.isError = isError
        self.images = images
    }
}

public protocol AgentToolProvider: Sendable {
    /// The tools currently on offer. May change between calls (an MCP server
    /// connecting or dropping).
    func tools() async -> [AgentToolSpec]

    /// The risk of this specific call. Defaults to the tool's static risk; a
    /// provider overrides it when the arguments matter (`read_file` on a path
    /// outside the working directory is not a plain read).
    func risk(forCall name: String, argumentsJSON: String, context: AgentToolContext) async -> ToolRisk

    /// One human line for the approval card, e.g. "运行命令：git status".
    func summary(forCall name: String, argumentsJSON: String) -> String

    func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput
}

public extension AgentToolProvider {
    func risk(forCall name: String, argumentsJSON: String, context: AgentToolContext) async -> ToolRisk {
        await tools().first { $0.name == name }?.risk ?? .execute
    }

    func summary(forCall name: String, argumentsJSON: String) -> String {
        let arguments = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        return arguments.isEmpty ? name : "\(name) \(arguments.prefix(200))"
    }
}

/// A call waiting for the user. Shown as a card in the thread.
public struct ToolApprovalRequest: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    /// The model's call id, so the card can sit beside its tool-call row.
    public var callID: String
    public var toolName: String
    public var source: String
    public var risk: ToolRisk
    public var argumentsJSON: String
    public var summary: String

    public init(
        id: UUID = UUID(), conversationID: UUID, callID: String, toolName: String,
        source: String, risk: ToolRisk, argumentsJSON: String, summary: String
    ) {
        self.id = id
        self.conversationID = conversationID
        self.callID = callID
        self.toolName = toolName
        self.source = source
        self.risk = risk
        self.argumentsJSON = argumentsJSON
        self.summary = summary
    }
}

public enum ToolApprovalDecision: String, Sendable {
    case allowOnce
    /// Allow this tool for the rest of the session.
    case allowAlways
    case deny
}
