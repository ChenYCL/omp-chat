import Foundation

/// Reads lightweight git facts for a working tree without shelling out.
public enum GitInfo {
    /// Current branch name, or short SHA when detached. Nil outside a repo.
    ///
    /// Works from any directory inside a checkout (it walks up to the
    /// repository root) and in linked worktrees, where `.git` is a file
    /// holding `gitdir: <path>` instead of a directory — exactly what
    /// 新建 Worktree creates.
    public static func branch(at directory: URL) -> String? {
        guard let gitDirectory = gitDirectory(from: directory) else { return nil }
        let headFile = gitDirectory.appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOf: headFile, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: ") {
            let ref = trimmed.dropFirst(5)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
        }
        return String(trimmed.prefix(7))
    }

    /// The directory holding `HEAD` for the checkout that contains
    /// `directory`, or nil when no ancestor is a git checkout.
    ///
    /// Walks string paths: `URL.deletingLastPathComponent()` turns `file:///`
    /// into `file:///../` instead of stopping, which never reaches a fixed
    /// point outside a repository.
    static func gitDirectory(from directory: URL) -> URL? {
        let fileManager = FileManager.default
        var current = directory.standardizedFileURL.path
        while true {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return URL(fileURLWithPath: dotGit, isDirectory: true) }
                // Linked worktree: `.git` is a file pointing at the real
                // per-worktree directory, relative paths being relative to it.
                guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
                let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let resolved = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                return URL(fileURLWithPath: (resolved as NSString).standardizingPath, isDirectory: true)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
        }
    }

    /// Abbreviates a path with `~` for the home directory.
    public static func tildified(_ path: String) -> String {
        let home = Self.homeDirectory().path
        guard path.hasPrefix(home) else { return path }
        let suffix = path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    private static func homeDirectory() -> URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}

/// What the composer's folder chip and the empty state's
/// 「你想让我们在 … 中构建什么？」 name.
public enum ThreadWorkspace {
    public static let defaultName = "默认工作区"

    /// The bound folder's name wins: it is where the thread actually works.
    /// Otherwise the project the thread belongs to, otherwise the default.
    public static func name(workingDirectory: String?, projectName: String?) -> String {
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespaces), !directory.isEmpty {
            let last = (directory as NSString).lastPathComponent
            return last.isEmpty || last == "/" ? directory : last
        }
        if let projectName, !projectName.isEmpty { return projectName }
        return defaultName
    }
}
