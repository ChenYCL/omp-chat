import Foundation

/// Project instructions from `AGENTS.md` files, the way Codex builds them
/// (developers.openai.com/codex/guides/agents-md):
///
/// - The project root is the nearest folder at or above the working
///   directory that holds `.git` (a folder or a worktree's file). Without one,
///   only the working directory itself is read.
/// - From the root down to the working directory, each folder contributes at
///   most one file: `AGENTS.override.md` if it exists, else `AGENTS.md`.
///   An empty (whitespace-only) file contributes nothing.
/// - Files are joined root → leaf with a blank line, so closer folders come
///   later and win.
/// - The combined text stops at `maxBytes` (32 KiB, Codex's
///   `project_doc_max_bytes`); the file that crosses the limit is cut there
///   and later files are not read. Unlike Codex, which truncates silently,
///   the cut is marked so the model knows text is missing.
public struct AgentsDoc: Equatable, Sendable {
    /// The joined instructions, ending in the truncation marker when cut.
    public var text: String
    /// Files that contributed, root → leaf.
    public var files: [String]
    public var truncated: Bool
    /// Nil when no `.git` was found above the working directory.
    public var projectRoot: String?
}

public enum AgentsMDLoader {
    public static let fileName = "AGENTS.md"
    public static let overrideFileName = "AGENTS.override.md"
    public static let defaultMaxBytes = 32 * 1024

    public static func truncationMarker(maxBytes: Int) -> String {
        "…（AGENTS.md 合计超过 \(maxBytes / 1024) KiB 上限，后面的内容没有载入）"
    }

    /// Nearest folder at or above `directory` containing `.git`.
    public static func projectRoot(for directory: String) -> String? {
        var current = (directory as NSString).standardizingPath
        while true {
            let marker = (current as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// Folders searched, root → leaf.
    public static func searchDirectories(for workingDirectory: String) -> [String] {
        let leaf = (workingDirectory as NSString).standardizingPath
        guard let root = projectRoot(for: leaf) else { return [leaf] }
        var directories: [String] = []
        var cursor = leaf
        while true {
            directories.append(cursor)
            if cursor == root { break }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor { break }
            cursor = parent
        }
        return directories.reversed()
    }

    /// The instructions for a thread bound to `workingDirectory`, or nil when
    /// the folder does not exist or no file has content.
    public static func load(workingDirectory: String, maxBytes: Int = defaultMaxBytes) -> AgentsDoc? {
        var isDirectory: ObjCBool = false
        guard maxBytes > 0,
              FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        var remaining = maxBytes
        var pieces: [String] = []
        var files: [String] = []
        var truncated = false
        for directory in searchDirectories(for: workingDirectory) {
            guard let path = candidate(in: directory), let data = FileManager.default.contents(atPath: path) else { continue }
            var text = String(decoding: data, as: UTF8.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard remaining > 0 else {
                // A file with content that no longer fits is lost to the cap.
                truncated = true
                break
            }
            if text.utf8.count > remaining {
                // The crossing file is cut at a character boundary and is
                // the last one read, as Codex stops once the budget is spent.
                text = prefix(text, bytes: remaining)
                truncated = true
                remaining = 0
            } else {
                remaining -= text.utf8.count
            }
            guard !text.isEmpty else { break }
            pieces.append(text)
            files.append(path)
        }
        guard !pieces.isEmpty else { return nil }
        var joined = pieces.joined(separator: "\n\n")
        if truncated { joined += "\n\n" + truncationMarker(maxBytes: maxBytes) }
        return AgentsDoc(text: joined, files: files, truncated: truncated, projectRoot: projectRoot(for: workingDirectory))
    }

    /// The one file a folder contributes: the override when it exists as a
    /// file, else `AGENTS.md`.
    private static func candidate(in directory: String) -> String? {
        for name in [overrideFileName, fileName] {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return path
            }
        }
        return nil
    }

    /// The longest prefix of `text` within `bytes` UTF-8 bytes that ends on a
    /// character boundary.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index...index].utf8.count
            if used + size > bytes { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
