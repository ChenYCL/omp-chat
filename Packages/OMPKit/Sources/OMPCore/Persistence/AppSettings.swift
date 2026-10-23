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

    public init(
        version: Int = 1,
        defaultProviderID: UUID? = nil,
        defaultModelID: String? = nil,
        sendOnReturn: Bool = true,
        appearance: AppearancePreference = .system,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        fontSize: Double = 15
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
    }
}
