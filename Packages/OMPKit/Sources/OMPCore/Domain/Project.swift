import Foundation

/// A sidebar grouping for conversations. Order is explicit so the user can
/// rearrange projects independently of their creation time.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var order: Int
    /// True when this grouping is a user-created custom section
    /// (ChatGPT `sidebarElectron.customSections`) rather than a project.
    public var isCustomSection: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        order: Int = 0,
        isCustomSection: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.order = order
        self.isCustomSection = isCustomSection
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, order, isCustomSection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isCustomSection = try container.decodeIfPresent(Bool.self, forKey: .isCustomSection) ?? false
    }
}
