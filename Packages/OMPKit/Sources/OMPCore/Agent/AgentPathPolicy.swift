import Foundation

/// Where a file tool's path really points, and what touching it is worth.
/// Paths are judged physically: every symlink is followed and `..` is applied
/// to what the link points at, the way the kernel resolves them, so neither
/// `../` nor a link inside the working directory can pass for "inside".
public enum AgentPathPolicy {
    public enum Access: Sendable {
        case read
        case write
    }

    /// The absolute path `raw` names: `~` expands to `home`, a relative path
    /// joins `workingDirectory`. Nil for an empty path, or a relative one when
    /// there is no working directory.
    public static func resolve(_ raw: String, workingDirectory: String?, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return join(home, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("/") { return trimmed }
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return join(workingDirectory, trimmed)
    }

    /// The physical path: symlinks followed (up to 40 hops, as the kernel
    /// allows), `.` and `..` applied. A missing tail is kept as written, so a
    /// file about to be created still resolves through its existing parents.
    public static func canonical(_ path: String) -> String {
        var pending = components(path)
        var resolved: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            if hops < 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if target.hasPrefix("/") { resolved = [] }
                pending = components(target) + pending
            } else {
                resolved.append(component)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// True when `path` is `root` or below it, both judged physically.
    public static func isInside(_ path: String, root: String) -> Bool {
        let target = canonical(path)
        let base = canonical(root)
        if base == "/" { return true }
        return target == base || target.hasPrefix(base + "/")
    }

    /// The risk of touching the already-resolved absolute `path`: inside the
    /// working directory a read is `.read` and a write `.write`; a read inside
    /// one of `readableRoots` is `.read`; anything else is `.execute`, the
    /// class that always asks outside full access.
    public static func risk(of path: String, access: Access, workingDirectory: String?, readableRoots: [String]) -> ToolRisk {
        if let workingDirectory, !workingDirectory.isEmpty, isInside(path, root: workingDirectory) {
            return access == .read ? .read : .write
        }
        if access == .read, readableRoots.contains(where: { !$0.isEmpty && isInside(path, root: $0) }) {
            return .read
        }
        return .execute
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func join(_ base: String, _ relative: String) -> String {
        base.hasSuffix("/") ? base + relative : base + "/" + relative
    }
}
