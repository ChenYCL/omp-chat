import Foundation

/// The sidebar's undo history (Codex `appUndo.*`): after an action the app
/// shows a toast with 撤销, and undoing puts the previous state back.
///
/// Inverses are data, not closures. Each records only the fields its action
/// changed, so applying it to a workspace that moved on since (new messages,
/// new chats, a later edit elsewhere) restores those fields and nothing else,
/// and a target that vanished in between is reported instead of resurrected.
public struct AppUndoStack: Equatable, Sendable {
    public static let defaultCapacity = 20

    public let capacity: Int
    /// Oldest first; the newest is what 撤销 and ⌘Z act on.
    public private(set) var entries: [AppUndoEntry] = []

    public init(capacity: Int = AppUndoStack.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var top: AppUndoEntry? { entries.last }

    /// Adds the newest entry, dropping the oldest beyond `capacity`.
    public mutating func push(_ entry: AppUndoEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public mutating func pop() -> AppUndoEntry? {
        entries.popLast()
    }
}

/// One undoable action.
public struct AppUndoEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Shown in the toast right after the action, e.g. 已归档「标题」.
    public let message: String
    /// Shown after a successful undo, e.g. 已恢复对话.
    public let confirmation: String
    public let inverse: AppUndoInverse

    public init(id: UUID = UUID(), message: String, confirmation: String, inverse: AppUndoInverse) {
        self.id = id
        self.message = message
        self.confirmation = confirmation
        self.inverse = inverse
    }
}

/// Whether a `Project` value is a project or a custom section; only changes
/// the wording.
public enum AppUndoGroupKind: String, Equatable, Sendable {
    case project
    case section

    public init(_ group: Project) {
        self = group.isCustomSection ? .section : .project
    }

    var noun: String { self == .section ? "分区" : "项目" }
}

/// A conversation's archive flags before an archive or unarchive. `isPinned`
/// is nil when the action left it alone (archiving only unpins pinned chats).
public struct AppUndoArchiveState: Equatable, Sendable {
    public var id: UUID
    public var isArchived: Bool
    public var isPinned: Bool?

    public init(id: UUID, isArchived: Bool, isPinned: Bool?) {
        self.id = id
        self.isArchived = isArchived
        self.isPinned = isPinned
    }
}

public struct AppUndoSortIndex: Equatable, Sendable {
    public var id: UUID
    public var sortIndex: Int?

    public init(id: UUID, sortIndex: Int?) {
        self.id = id
        self.sortIndex = sortIndex
    }
}

/// How to take one action back, with the values it overwrote.
public enum AppUndoInverse: Equatable, Sendable {
    case archive([AppUndoArchiveState])
    case pin(conversationID: UUID, wasPinned: Bool)
    case rename(conversationID: UUID, previousTitle: String)
    case move(conversationID: UUID, previousProjectID: UUID?)
    /// Previous manual indexes of the chats the reorder touched.
    case reorder([AppUndoSortIndex])
    case createGroup(projectID: UUID, kind: AppUndoGroupKind)
    case renameGroup(projectID: UUID, kind: AppUndoGroupKind, previousName: String)
    /// The deleted group, its index in the workspace's `projects`, and the
    /// chats it held.
    case deleteGroup(Project, position: Int, memberIDs: [UUID])
    /// A composer attachment removed from the draft of `conversationID`
    /// (nil: the draft with no conversation selected).
    case removeAttachment(MediaRef, position: Int, conversationID: UUID?)
}

/// The state inverses read and write.
public struct AppUndoWorkspace: Sendable {
    public var conversations: [Conversation]
    public var projects: [Project]
    /// The conversation whose draft the composer shows.
    public var composerConversationID: UUID?
    public var composerAttachments: [MediaRef]
    /// Drafts of the conversations not on screen.
    public var parkedAttachments: [UUID: [MediaRef]]

    public init(
        conversations: [Conversation],
        projects: [Project],
        composerConversationID: UUID? = nil,
        composerAttachments: [MediaRef] = [],
        parkedAttachments: [UUID: [MediaRef]] = [:]
    ) {
        self.conversations = conversations
        self.projects = projects
        self.composerConversationID = composerConversationID
        self.composerAttachments = composerAttachments
        self.parkedAttachments = parkedAttachments
    }
}

/// What an applied inverse touched, so the caller persists exactly that.
public struct AppUndoChanges: Equatable, Sendable {
    public var conversationIDs: [UUID] = []
    public var projects = false
    public var attachments = false

    public init(conversationIDs: [UUID] = [], projects: Bool = false, attachments: Bool = false) {
        self.conversationIDs = conversationIDs
        self.projects = projects
        self.attachments = attachments
    }
}

public enum AppUndoOutcome: Equatable, Sendable {
    case restored(AppUndoChanges)
    /// Nothing was changed; the text says why.
    case failed(String)
}

extension AppUndoInverse {
    static let conversationGone = "无法撤销：对话已被删除"

    static func groupGone(_ kind: AppUndoGroupKind) -> String {
        "无法撤销：\(kind.noun)已被删除"
    }

    public func apply(to workspace: inout AppUndoWorkspace) -> AppUndoOutcome {
        switch self {
        case .archive(let states):
            var changed: [UUID] = []
            for state in states {
                guard let index = workspace.conversations.firstIndex(where: { $0.id == state.id }) else { continue }
                workspace.conversations[index].isArchived = state.isArchived
                if let pinned = state.isPinned {
                    workspace.conversations[index].isPinned = pinned
                }
                changed.append(state.id)
            }
            return changed.isEmpty ? .failed(Self.conversationGone) : .restored(AppUndoChanges(conversationIDs: changed))

        case .pin(let id, let wasPinned):
            return updateConversation(id, in: &workspace) { $0.isPinned = wasPinned }

        case .rename(let id, let previousTitle):
            return updateConversation(id, in: &workspace) { $0.title = previousTitle }

        case .move(let id, let previousProjectID):
            guard workspace.conversations.contains(where: { $0.id == id }) else { return .failed(Self.conversationGone) }
            // A chat pointing at a group that no longer exists would vanish
            // from every sidebar section.
            if let previousProjectID, !workspace.projects.contains(where: { $0.id == previousProjectID }) {
                return .failed("无法撤销：原来所在的分组已被删除")
            }
            return updateConversation(id, in: &workspace) { $0.projectID = previousProjectID }

        case .reorder(let previous):
            var changed: [UUID] = []
            for item in previous {
                guard let index = workspace.conversations.firstIndex(where: { $0.id == item.id }) else { continue }
                workspace.conversations[index].sortIndex = item.sortIndex
                changed.append(item.id)
            }
            return changed.isEmpty ? .failed(Self.conversationGone) : .restored(AppUndoChanges(conversationIDs: changed))

        case .createGroup(let id, let kind):
            guard workspace.projects.contains(where: { $0.id == id }) else { return .failed(Self.groupGone(kind)) }
            workspace.projects.removeAll { $0.id == id }
            // Same as deleting it: chats filed into it since go back to ungrouped.
            var changed: [UUID] = []
            for index in workspace.conversations.indices where workspace.conversations[index].projectID == id {
                workspace.conversations[index].projectID = nil
                changed.append(workspace.conversations[index].id)
            }
            return .restored(AppUndoChanges(conversationIDs: changed, projects: true))

        case .renameGroup(let id, let kind, let previousName):
            guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return .failed(Self.groupGone(kind)) }
            workspace.projects[index].name = previousName
            return .restored(AppUndoChanges(projects: true))

        case .deleteGroup(let group, let position, let memberIDs):
            var changes = AppUndoChanges()
            if !workspace.projects.contains(where: { $0.id == group.id }) {
                workspace.projects.insert(group, at: min(max(0, position), workspace.projects.count))
                changes.projects = true
            }
            // Deleting left the members ungrouped; a member filed elsewhere
            // since stays where the user put it.
            let members = Set(memberIDs)
            for index in workspace.conversations.indices
            where members.contains(workspace.conversations[index].id) && workspace.conversations[index].projectID == nil {
                workspace.conversations[index].projectID = group.id
                changes.conversationIDs.append(workspace.conversations[index].id)
            }
            return .restored(changes)

        case .removeAttachment(let ref, let position, let conversationID):
            if conversationID == workspace.composerConversationID {
                guard !workspace.composerAttachments.contains(where: { $0.id == ref.id }) else { return .restored(AppUndoChanges()) }
                workspace.composerAttachments.insert(ref, at: min(max(0, position), workspace.composerAttachments.count))
                return .restored(AppUndoChanges(attachments: true))
            }
            guard let conversationID, workspace.conversations.contains(where: { $0.id == conversationID }) else {
                return .failed(Self.conversationGone)
            }
            var parked = workspace.parkedAttachments[conversationID] ?? []
            guard !parked.contains(where: { $0.id == ref.id }) else { return .restored(AppUndoChanges()) }
            parked.insert(ref, at: min(max(0, position), parked.count))
            workspace.parkedAttachments[conversationID] = parked
            return .restored(AppUndoChanges(attachments: true))
        }
    }

    private func updateConversation(
        _ id: UUID,
        in workspace: inout AppUndoWorkspace,
        _ body: (inout Conversation) -> Void
    ) -> AppUndoOutcome {
        guard let index = workspace.conversations.firstIndex(where: { $0.id == id }) else { return .failed(Self.conversationGone) }
        body(&workspace.conversations[index])
        return .restored(AppUndoChanges(conversationIDs: [id]))
    }
}

// MARK: - Entries for each action

extension AppUndoEntry {
    /// Archiving or unarchiving one chat; `before` is the chat as it was.
    public static func toggledArchive(_ before: Conversation) -> AppUndoEntry {
        let state = AppUndoArchiveState(
            id: before.id,
            isArchived: before.isArchived,
            isPinned: !before.isArchived && before.isPinned ? true : nil
        )
        return AppUndoEntry(
            message: before.isArchived ? "已取消归档「\(before.title)」" : "已归档「\(before.title)」",
            confirmation: before.isArchived ? "已重新归档" : "已恢复对话",
            inverse: .archive([state])
        )
    }

    /// Archiving several chats at once; `before` holds only the ones the
    /// action archived. Nil when it archived none.
    public static func archived(_ before: [Conversation]) -> AppUndoEntry? {
        guard !before.isEmpty else { return nil }
        let states = before.map {
            AppUndoArchiveState(id: $0.id, isArchived: $0.isArchived, isPinned: $0.isPinned ? true : nil)
        }
        return AppUndoEntry(
            message: "已归档 \(before.count) 个对话",
            confirmation: "已恢复 \(before.count) 个对话",
            inverse: .archive(states)
        )
    }

    public static func toggledPin(_ before: Conversation) -> AppUndoEntry {
        AppUndoEntry(
            message: before.isPinned ? "已取消置顶「\(before.title)」" : "已置顶「\(before.title)」",
            confirmation: before.isPinned ? "已恢复置顶" : "已取消置顶",
            inverse: .pin(conversationID: before.id, wasPinned: before.isPinned)
        )
    }

    /// Nil when the title did not change.
    public static func renamed(_ before: Conversation, to title: String) -> AppUndoEntry? {
        guard before.title != title else { return nil }
        return AppUndoEntry(
            message: "已重命名为「\(title)」",
            confirmation: "已恢复对话名称",
            inverse: .rename(conversationID: before.id, previousTitle: before.title)
        )
    }

    /// Nil when the chat already was there. `destination` is the group it
    /// moved into, nil when it left its group.
    public static func moved(_ before: Conversation, to destination: Project?) -> AppUndoEntry? {
        guard before.projectID != destination?.id else { return nil }
        return AppUndoEntry(
            message: destination.map { "已移到「\($0.name)」" } ?? "已移出分组",
            confirmation: "已移回原处",
            inverse: .move(conversationID: before.id, previousProjectID: before.projectID)
        )
    }

    /// `before` are the reordered chats as they were. Nil when no index changes.
    public static func reordered(_ before: [Conversation], newIndexes: [UUID: Int]) -> AppUndoEntry? {
        guard before.contains(where: { $0.sortIndex != newIndexes[$0.id] }) else { return nil }
        return AppUndoEntry(
            message: "已调整对话顺序",
            confirmation: "已恢复排序",
            inverse: .reorder(before.map { AppUndoSortIndex(id: $0.id, sortIndex: $0.sortIndex) })
        )
    }

    public static func createdGroup(_ group: Project) -> AppUndoEntry {
        let kind = AppUndoGroupKind(group)
        return AppUndoEntry(
            message: "已新建\(kind.noun)「\(group.name)」",
            confirmation: "已撤销新建\(kind.noun)",
            inverse: .createGroup(projectID: group.id, kind: kind)
        )
    }

    /// Nil when the name did not change.
    public static func renamedGroup(_ before: Project, to name: String) -> AppUndoEntry? {
        guard before.name != name else { return nil }
        let kind = AppUndoGroupKind(before)
        return AppUndoEntry(
            message: "已将\(kind.noun)重命名为「\(name)」",
            confirmation: kind == .section ? "已撤销分区修改" : "已恢复项目名称",
            inverse: .renameGroup(projectID: before.id, kind: kind, previousName: before.name)
        )
    }

    /// `position` is the group's index in the workspace's `projects`.
    public static func deletedGroup(_ group: Project, position: Int, memberIDs: [UUID]) -> AppUndoEntry {
        let kind = AppUndoGroupKind(group)
        return AppUndoEntry(
            message: "已删除\(kind.noun)「\(group.name)」",
            confirmation: "已恢复\(kind.noun)",
            inverse: .deleteGroup(group, position: position, memberIDs: memberIDs)
        )
    }

    public static func removedAttachment(_ ref: MediaRef, position: Int, conversationID: UUID?) -> AppUndoEntry {
        AppUndoEntry(
            message: "已移除附件",
            confirmation: "已恢复附件",
            inverse: .removeAttachment(ref, position: position, conversationID: conversationID)
        )
    }
}

/// What the bottom toast shows: an action that 撤销 can take back, or the
/// result of an undo.
public struct AppUndoToast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String
    /// True for an action (shows 撤销), false for an undo's result.
    public let offersUndo: Bool

    public init(id: UUID = UUID(), message: String, offersUndo: Bool) {
        self.id = id
        self.message = message
        self.offersUndo = offersUndo
    }
}
