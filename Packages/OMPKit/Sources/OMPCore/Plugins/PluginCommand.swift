import Foundation

/// One shell command a plugin needs: a hook handler or a `git clone`.
///
/// OMPCore does not spawn processes itself. The app's `HostExecutor` owns the
/// child environment (real HOME, a PATH that sees `~/.local/bin` and
/// Homebrew) and process-tree cleanup, so the store and the hook runner take a
/// `PluginCommandRunner` that does the spawning.
public struct PluginCommand: Sendable, Equatable {
    /// One `zsh` command line.
    public var command: String
    public var cwd: String
    /// Written to the child's stdin and then closed; nil gives it EOF.
    public var stdin: Data?
    /// Seconds before the whole process tree is stopped.
    public var timeout: Double
    /// Added on top of the child environment.
    public var environment: [String: String]
    /// Runs under a login shell (`zsh -lc`), as Codex runs hook commands.
    public var loginShell: Bool

    public init(
        command: String, cwd: String, stdin: Data? = nil, timeout: Double,
        environment: [String: String] = [:], loginShell: Bool = false
    ) {
        self.command = command
        self.cwd = cwd
        self.stdin = stdin
        self.timeout = timeout
        self.environment = environment
        self.loginShell = loginShell
    }
}

public struct PluginCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// Set when the command could not be started at all.
    public var launchError: String?

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, launchError: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchError = launchError
    }
}

public typealias PluginCommandRunner = @Sendable (PluginCommand) async -> PluginCommandResult

extension PluginCommand {
    /// Single-quotes `value` for a `zsh -c` line, so spaces and quotes survive.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
