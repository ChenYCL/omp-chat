import Foundation

/// How the desktop sidebar groups conversations (Codex `sidebarElectron.groupByMenu`).
public enum SidebarGrouping: String, CaseIterable, Sendable {
    /// Today's layout: projects, custom sections, Recents by date.
    case project = "project"
    /// Recents splits into one group per provider instead of date buckets.
    case connection = "connection"

    public init(stored value: String) {
        self = SidebarGrouping(rawValue: value) ?? .project
    }
}

/// Which conversations the sidebar lists (Codex `flatProjectSidebar.filter`).
public enum SidebarFilter: String, CaseIterable, Sendable {
    case all = "all"
    /// Not bound to a working directory.
    case chat = "chat"
    /// Bound to a working directory.
    case work = "work"

    public init(stored value: String) {
        self = SidebarFilter(rawValue: value) ?? .all
    }

    /// Chat is unbound; work is bound. Archived, locked and temporary
    /// conversations are already absent from the input the sidebar feeds in
    /// (`sortedConversations` drops them), so this rule does not re-decide that.
    public func includes(_ conversation: Conversation) -> Bool {
        switch self {
        case .all: return true
        case .chat: return conversation.workingDirectory == nil
        case .work: return conversation.workingDirectory != nil
        }
    }
}

/// Pure sidebar shaping shared by both shells, so the filter and the
/// connection grouping behave the same wherever they are drawn.
public enum SidebarOrganization {
    /// One provider's conversations. `name` is the provider's display name,
    /// or 未知连接 when the provider is missing or unknown.
    public struct ConnectionGroup: Equatable, Sendable {
        public var name: String
        /// The provider, when one resolved; nil for the 未知连接 group.
        public var providerID: UUID?
        public var conversations: [Conversation]

        public init(name: String, providerID: UUID?, conversations: [Conversation]) {
            self.name = name
            self.providerID = providerID
            self.conversations = conversations
        }
    }

    public static let unknownConnectionName = "未知连接"

    public static func filter(_ conversations: [Conversation], by filter: SidebarFilter) -> [Conversation] {
        conversations.filter { filter.includes($0) }
    }

    /// Groups by the conversation's provider, resolved to that provider's name.
    /// Groups come out ordered by their most recent activity; the conversations
    /// inside a group keep the order they had in `conversations`.
    public static func connectionGroups(
        _ conversations: [Conversation],
        providers: [ProviderProfile]
    ) -> [ConnectionGroup] {
        let names = Dictionary(providers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var order: [GroupKey] = []
        var buckets: [GroupKey: [Conversation]] = [:]
        for conversation in conversations {
            let key = groupKey(for: conversation, names: names)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(conversation)
        }
        return order
            .sorted { lhs, rhs in
                let left = buckets[lhs]?.first?.updatedAt ?? .distantPast
                let right = buckets[rhs]?.first?.updatedAt ?? .distantPast
                if left != right { return left > right }
                return (buckets[lhs]?.first?.id.uuidString ?? "") < (buckets[rhs]?.first?.id.uuidString ?? "")
            }
            .map { key in
                ConnectionGroup(
                    name: key.name,
                    providerID: key.providerID,
                    conversations: buckets[key] ?? []
                )
            }
    }

    private struct GroupKey: Hashable {
        var providerID: UUID?
        var name: String
    }

    private static func groupKey(for conversation: Conversation, names: [UUID: String]) -> GroupKey {
        guard let id = conversation.providerID, let name = names[id] else {
            return GroupKey(providerID: nil, name: unknownConnectionName)
        }
        return GroupKey(providerID: id, name: name)
    }
}
