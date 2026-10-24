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
    /// Global custom instructions appended after the base system prompt
    /// (ChatGPT `settings.personalization.customInstructions`).
    public var customInstructions: String
    /// Remember context between chats (memory.enableMemories).
    public var enableMemories: Bool
    /// Custom accent color hex; empty means follow the system tint.
    public var accentColorHex: String
    /// Notify when a reply finishes while the app is in the background.
    public var completionNotifications: Bool

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
        customInstructions: String = "",
        enableMemories: Bool = false,
        accentColorHex: String = "",
        completionNotifications: Bool = false
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
        self.customInstructions = customInstructions
        self.enableMemories = enableMemories
        self.accentColorHex = accentColorHex
        self.completionNotifications = completionNotifications
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
        customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        enableMemories = try container.decodeIfPresent(Bool.self, forKey: .enableMemories) ?? false
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? ""
        completionNotifications = try container.decodeIfPresent(Bool.self, forKey: .completionNotifications) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case version, defaultProviderID, defaultModelID, sendOnReturn, appearance
        case systemPrompt, temperature, maxOutputTokens, fontSize, soundEffects
        case showLineNumbers, codeFontName, speechRateMultiplier, speechVoiceLanguage
        case conversationSort, customInstructions, enableMemories, accentColorHex
        case completionNotifications
    }
}
