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

public extension PermissionMode {
    /// The mode a reply may run under when it was started from a paired phone.
    ///
    /// 「允许手机访问文件与终端」 is the user's consent for the phone to touch
    /// the Mac's files and shell. Without it, a phone prompting a conversation
    /// whose mode is 自动 or 完全访问 would get commands run unasked, so such a
    /// reply is held to 每次询问: the cards appear on the Mac and only the Mac
    /// can allow them. 只读 and 每次询问 are already at least that strict, and a
    /// reply started on the Mac itself is never limited.
    func limited(remoteDriven: Bool, phoneMayTouchMac: Bool) -> PermissionMode {
        guard remoteDriven, !phoneMayTouchMac else { return self }
        switch self {
        case .readOnly, .ask: return self
        case .auto, .full: return .ask
        }
    }
}
