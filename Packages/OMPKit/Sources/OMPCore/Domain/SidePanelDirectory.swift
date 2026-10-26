import Foundation

/// Which directory the side panel's 文件 / 改动 tabs — and a terminal that is
/// not mid-command — should work in.
///
/// Codex's side panel follows the thread: a thread bound to a repository
/// (`Conversation.workingDirectory`) shows that repository, and a thread with
/// no binding keeps whatever the panel already points at, including a folder
/// the user picked by hand. The rule is extracted here because it decides
/// what three different views display and the tests must pin it down.
public enum SidePanelDirectory {
    /// The directory the panel should show.
    ///
    /// - Parameters:
    ///   - threadDirectory: the selected conversation's `workingDirectory`.
    ///   - current: what the panel is currently showing.
    /// - Returns: the thread's directory when the thread has one, otherwise
    ///   `current` unchanged.
    public static func resolve(threadDirectory: String?, current: String) -> String {
        guard let threadDirectory, !threadDirectory.isEmpty else { return current }
        return threadDirectory
    }
}
