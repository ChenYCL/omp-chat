import Foundation

public enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

/// User-level preferences. Lives beside conversations in the same store file
/// so a single atomic write keeps the workspace consistent.
public struct AppSettings: Codable, Hashable, Sendable {
    public var version: Int
    public var defaultProviderID: UUID?
    public var defaultModelID: String?
    public var sendOnReturn: Bool
    public var appearance: AppearancePreference
    public var systemPrompt: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// Message text size in points.
    public var fontSize: Double
    public var soundEffects: Bool
    public var showLineNumbers: Bool
    public var codeFontName: String
    public var speechRateMultiplier: Double
    public var speechVoiceLanguage: String
    /// Sidebar ordering: "updated" (default), "created", or "manual".
    public var conversationSort: String
    /// Sidebar grouping: "project" (default) or "connection".
    public var sidebarGrouping: String
    /// Sidebar filter: "all" (default), "chat", or "work".
    public var sidebarFilter: String
    /// Global custom instructions appended after the base system prompt
    /// (ChatGPT `settings.personalization.customInstructions`).
    public var customInstructions: String
    /// Master switch for memories (memory.enableMemories).
    public var enableMemories: Bool
    /// One memory per line, typed by the user. When `enableMemories` is on these
    /// are appended to the system prompt; the switch used to control nothing.
    public var memories: String
    /// Custom accent color hex; empty means follow the system tint.
    public var accentColorHex: String
    /// Notify when a reply finishes while the app is in the background.
    public var completionNotifications: Bool
    /// iOS, legacy: the single-Mac connection from before `pairedDevices`.
    /// Only read by `foldLegacyConnection()`; nothing writes these any more.
    public var remoteHost: String
    public var remotePort: UInt16
    public var remoteToken: String
    /// LAN relay host side (macOS): pairing token persisted on first enable.
    public var relayToken: String
    /// LAN relay host side (macOS): HTTP listen port.
    public var relayPort: UInt16
    /// LAN relay host side (macOS): whether the relay server is enabled.
    public var relayEnabled: Bool
    /// Relay hub host side (macOS): public hub base URL. Empty = LAN-only mode.
    public var relayHubURL: String
    /// Relay hub host side (macOS): 6-character room code shared with the phone.
    public var relayRoomCode: String
    /// iOS, legacy: hub URL and room code from before `pairedDevices`; folded
    /// into the device list (room code into the vault) on load.
    public var remoteHubURL: String
    public var remoteRoomCode: String
    /// Relay host side (macOS): allow a paired phone to read files and run
    /// shell commands. Off by default; `info` stays available either way.
    public var relayAllowShell: Bool
    /// iOS: every Mac this phone has paired with, newest first.
    public var pairedDevices: [PairedDevice]
    /// macOS: where 新建 Worktree checkouts live. Empty = beside the repository.
    public var worktreeBaseDirectory: String
    /// macOS: prefix for new worktree branch names, e.g. "omp". Empty = none.
    public var worktreeBranchPrefix: String

    public init(
        version: Int = 1,
        defaultProviderID: UUID? = nil,
        defaultModelID: String? = nil,
        sendOnReturn: Bool = true,
        appearance: AppearancePreference = .system,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        fontSize: Double = 15,
        soundEffects: Bool = true,
        showLineNumbers: Bool = true,
        codeFontName: String = "SF Mono",
        speechRateMultiplier: Double = 1.0,
        speechVoiceLanguage: String = "zh-CN",
        conversationSort: String = "updated",
        sidebarGrouping: String = "project",
        sidebarFilter: String = "all",
        customInstructions: String = "",
        enableMemories: Bool = false,
        memories: String = "",
        accentColorHex: String = "",
        completionNotifications: Bool = false,
        remoteHost: String = "",
        remotePort: UInt16 = 8790,
        remoteToken: String = "",
        relayToken: String = "",
        relayPort: UInt16 = 8790,
        relayEnabled: Bool = false,
        relayHubURL: String = "",
        relayRoomCode: String = "",
        remoteHubURL: String = "",
        remoteRoomCode: String = "",
        relayAllowShell: Bool = false,
        worktreeBaseDirectory: String = "",
        worktreeBranchPrefix: String = "",
        pairedDevices: [PairedDevice] = []
    ) {
        self.version = version
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.sendOnReturn = sendOnReturn
        self.appearance = appearance
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.fontSize = fontSize
        self.soundEffects = soundEffects
        self.showLineNumbers = showLineNumbers
        self.codeFontName = codeFontName
        self.speechRateMultiplier = speechRateMultiplier
        self.speechVoiceLanguage = speechVoiceLanguage
        self.conversationSort = conversationSort
        self.sidebarGrouping = sidebarGrouping
        self.sidebarFilter = sidebarFilter
        self.customInstructions = customInstructions
        self.enableMemories = enableMemories
        self.memories = memories
        self.accentColorHex = accentColorHex
        self.completionNotifications = completionNotifications
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.remoteToken = remoteToken
        self.relayToken = relayToken
        self.relayPort = relayPort
        self.relayEnabled = relayEnabled
        self.relayHubURL = relayHubURL
        self.relayRoomCode = relayRoomCode
        self.remoteHubURL = remoteHubURL
        self.remoteRoomCode = remoteRoomCode
        self.relayAllowShell = relayAllowShell
        self.pairedDevices = pairedDevices
        self.worktreeBaseDirectory = worktreeBaseDirectory
        self.worktreeBranchPrefix = worktreeBranchPrefix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        defaultProviderID = try container.decodeIfPresent(UUID.self, forKey: .defaultProviderID)
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
        sendOnReturn = try container.decodeIfPresent(Bool.self, forKey: .sendOnReturn) ?? true
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 15
        soundEffects = try container.decodeIfPresent(Bool.self, forKey: .soundEffects) ?? true
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        codeFontName = try container.decodeIfPresent(String.self, forKey: .codeFontName) ?? "SF Mono"
        speechRateMultiplier = try container.decodeIfPresent(Double.self, forKey: .speechRateMultiplier) ?? 1.0
        speechVoiceLanguage = try container.decodeIfPresent(String.self, forKey: .speechVoiceLanguage) ?? "zh-CN"
        conversationSort = try container.decodeIfPresent(String.self, forKey: .conversationSort) ?? "updated"
        sidebarGrouping = try container.decodeIfPresent(String.self, forKey: .sidebarGrouping) ?? "project"
        sidebarFilter = try container.decodeIfPresent(String.self, forKey: .sidebarFilter) ?? "all"
        customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        enableMemories = try container.decodeIfPresent(Bool.self, forKey: .enableMemories) ?? false
        memories = try container.decodeIfPresent(String.self, forKey: .memories) ?? ""
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? ""
        completionNotifications = try container.decodeIfPresent(Bool.self, forKey: .completionNotifications) ?? false
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        remotePort = try container.decodeIfPresent(UInt16.self, forKey: .remotePort) ?? 8790
        remoteToken = try container.decodeIfPresent(String.self, forKey: .remoteToken) ?? ""
        relayToken = try container.decodeIfPresent(String.self, forKey: .relayToken) ?? ""
        relayPort = try container.decodeIfPresent(UInt16.self, forKey: .relayPort) ?? 8790
        relayEnabled = try container.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? false
        relayHubURL = try container.decodeIfPresent(String.self, forKey: .relayHubURL) ?? ""
        relayRoomCode = try container.decodeIfPresent(String.self, forKey: .relayRoomCode) ?? ""
        remoteHubURL = try container.decodeIfPresent(String.self, forKey: .remoteHubURL) ?? ""
        remoteRoomCode = try container.decodeIfPresent(String.self, forKey: .remoteRoomCode) ?? ""
        relayAllowShell = try container.decodeIfPresent(Bool.self, forKey: .relayAllowShell) ?? false
        pairedDevices = try container.decodeIfPresent([PairedDevice].self, forKey: .pairedDevices) ?? []
        worktreeBaseDirectory = try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectory) ?? ""
        worktreeBranchPrefix = try container.decodeIfPresent(String.self, forKey: .worktreeBranchPrefix) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case version, defaultProviderID, defaultModelID, sendOnReturn, appearance
        case systemPrompt, temperature, maxOutputTokens, fontSize, soundEffects
        case showLineNumbers, codeFontName, speechRateMultiplier, speechVoiceLanguage
        case conversationSort, sidebarGrouping, sidebarFilter, customInstructions, enableMemories, memories, accentColorHex
        case completionNotifications
        case remoteHost, remotePort, remoteToken
        case relayToken, relayPort, relayEnabled
        case relayHubURL, relayRoomCode, remoteHubURL, remoteRoomCode
        case relayAllowShell, pairedDevices
        case worktreeBaseDirectory, worktreeBranchPrefix
    }
}
