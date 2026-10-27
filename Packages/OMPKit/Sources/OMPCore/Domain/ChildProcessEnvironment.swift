import Foundation

/// Environment for child processes, shared by everything that spawns one:
/// the relay's exec, MCP servers, builtin shell tools, git and the local
/// environment scripts. One implementation, so every child sees the account's
/// real home and a PATH that finds user-installed tools.
public enum ChildProcessEnvironment {
    /// Account home from `getpwuid`, falling back to `NSHomeDirectory()` only
    /// when the passwd entry is missing. `NSHomeDirectory()` alone is wrong
    /// inside the app sandbox: it returns the container, not the home.
    public static func realHomeDirectory() -> String {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        #endif
        return NSHomeDirectory()
    }

    /// The child's environment: the current process environment with `HOME`
    /// pointed at the account's real home, plus the common tool directories
    /// prepended to `PATH` (a Finder-launched app inherits launchd's minimal
    /// PATH; agent CLIs install per user).
    public static func build(home: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let resolvedHome = home ?? realHomeDirectory()
        if !resolvedHome.isEmpty {
            environment["HOME"] = resolvedHome
        }
        #if os(macOS)
        let user = realHomeDirectory()
        let extras = ["\(user)/.local/bin", "\(user)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let current = environment["PATH"] ?? "/usr/bin:/bin"
        let missing = extras.filter { !current.split(separator: ":").contains(Substring($0)) }
        if !missing.isEmpty {
            environment["PATH"] = (missing + [current]).joined(separator: ":")
        }
        #endif
        return environment
    }
}
