import Foundation

/// Decides whether one tool call runs, asks the user first, or is refused,
/// from the conversation's permission mode and the call's risk.
public enum ApprovalPolicy {
    public enum Decision: String, Equatable, Sendable {
        case allow
        case ask
        case deny
    }

    /// | mode     | read  | write | execute | control |
    /// |----------|-------|-------|---------|---------|
    /// | readOnly | allow | deny  | deny    | deny    |
    /// | ask      | allow | ask   | ask     | ask     |
    /// | auto     | allow | allow | ask     | ask     |
    /// | full     | allow | allow | allow   | ask     |
    ///
    /// `alwaysAllowed` (the user chose 始终允许 for this tool) turns an ask
    /// into an allow; it never overrides a deny, and never applies to
    /// `.control`: driving the desktop asks every time.
    public static func decide(mode: PermissionMode, risk: ToolRisk, alwaysAllowed: Bool) -> Decision {
        let base: Decision
        switch (mode, risk) {
        case (_, .read):
            base = .allow
        case (.readOnly, _):
            base = .deny
        case (.ask, _):
            base = .ask
        case (.auto, .write):
            base = .allow
        case (.auto, _):
            base = .ask
        case (.full, .control):
            base = .ask
        case (.full, _):
            base = .allow
        }
        return base == .ask && alwaysAllowed && risk != .control ? .allow : base
    }
}
