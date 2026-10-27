import Foundation

/// Everything the Worktree settings pane and the restore banner show about
/// one managed worktree, gathered off the main actor. Views read this cache;
/// nothing in `body` touches the disk or git.
public struct ManagedWorktreeDetail: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let sourceRoot: String
    /// The branch's name, or 「已分离」 when the worktree sits on a detached
    /// HEAD, or 「已删除」 when the registry row is a snapshot of a deleted
    /// worktree.
    public let branchLabel: String
    public let createdAt: Date
    public let environmentPath: String?
    /// Repository-root-relative conversation titles, ordered as registered.
    public let conversationTitles: [UUID]
    public let linkedConversationTitles: [String]
    public let sizeOnDisk: Int64?
    public let existsOnDisk: Bool
    public let deleted: Bool

    public static func == (lhs: ManagedWorktreeDetail, rhs: ManagedWorktreeDetail) -> Bool {
        lhs.id == rhs.id && lhs.branchLabel == rhs.branchLabel
            && lhs.sizeOnDisk == rhs.sizeOnDisk && lhs.existsOnDisk == rhs.existsOnDisk
            && lhs.linkedConversationTitles == rhs.linkedConversationTitles
    }
}
