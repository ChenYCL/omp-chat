import Foundation

/// The composer's single 「工具与权限」 choice, like Codex's Chat / Agent /
/// Agent (full access) picker: whether a thread gets tools and, if it does,
/// how freely they run.
///
/// It is stored as two optional fields on the conversation (`toolsEnabled`,
/// `permissionMode`). The menu used to show them as two separate controls,
/// which let a thread sit at 仅聊天 with 完全访问 checked: picking a mode while
/// tools were off was saved and changed nothing visible. One radio list over
/// this type means exactly one entry is checked and every pick shows.
public enum AgentAccess: Hashable, Sendable {
    /// Both fields unset: tools when the thread has a working directory, in
    /// the settings' default mode.
    case followDefault
    case chatOnly
    case tools(PermissionMode)

    /// Every choice in menu order.
    public static let allChoices: [AgentAccess] =
        [.followDefault, .chatOnly] + PermissionMode.allCases.map(AgentAccess.tools)

    /// What the menu checks for the stored fields. Both unset is 跟随默认 and
    /// explicit tools-off is 仅聊天; otherwise the mode tools would run in.
    /// A mode stored while tools follow the working directory (older
    /// versions could save that) shows what the thread really gets.
    public static func current(
        toolsEnabled: Bool?, permissionMode: PermissionMode?,
        hasWorkingDirectory: Bool, defaultMode: PermissionMode
    ) -> AgentAccess {
        switch (toolsEnabled, permissionMode) {
        case (nil, nil): .followDefault
        case (false?, _): .chatOnly
        case (true?, let mode): .tools(mode ?? defaultMode)
        case (nil, let mode?): hasWorkingDirectory ? .tools(mode) : .chatOnly
        }
    }

    /// The fields to store for this choice. 仅聊天 clears the mode, so no
    /// hidden setting comes back when tools are turned on again.
    public var stored: (toolsEnabled: Bool?, permissionMode: PermissionMode?) {
        switch self {
        case .followDefault: (nil, nil)
        case .chatOnly: (false, nil)
        case .tools(let mode): (true, mode)
        }
    }

    /// What the thread actually gets; never `.followDefault`.
    public func resolved(hasWorkingDirectory: Bool, defaultMode: PermissionMode) -> AgentAccess {
        guard self == .followDefault else { return self }
        return hasWorkingDirectory ? .tools(defaultMode) : .chatOnly
    }

    public var title: String {
        switch self {
        case .followDefault: "跟随默认"
        case .chatOnly: "仅聊天"
        case .tools(let mode): mode.title
        }
    }

    /// The name `/debug/action setAccess` and `/debug/state` use.
    public var wireValue: String {
        switch self {
        case .followDefault: "default"
        case .chatOnly: "chat"
        case .tools(let mode): mode.rawValue
        }
    }

    public init?(wireValue: String) {
        switch wireValue {
        case "default": self = .followDefault
        case "chat": self = .chatOnly
        default:
            guard let mode = PermissionMode(rawValue: wireValue) else { return nil }
            self = .tools(mode)
        }
    }
}
