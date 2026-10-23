import Foundation

/// A sidebar grouping for conversations. Order is explicit so the user can
/// rearrange projects independently of their creation time.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var order: Int

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.order = order
    }
}
