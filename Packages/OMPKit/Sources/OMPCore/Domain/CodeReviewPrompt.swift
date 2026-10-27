import Foundation

/// 「用 Codex 审查」 (official `codeReview.menu.review`): a working tree's
/// uncommitted changes as one request to a read-only review thread.
///
/// `collect` reads the changes through `GitWorkingTree`; `build` is pure. The
/// changes are capped at `budget` bytes. A file that does not fit is left out
/// whole — never cut mid-hunk — while later, smaller files still go in, and
/// the request names every file it left out so the reviewer can read them
/// itself.
public enum CodeReviewPrompt {
    /// About 80 KB of changes per request.
    public static let budget = 80 * 1024

    /// One file's share of the changes.
    public struct FileChange: Equatable, Sendable {
        public var path: String
        /// A unified diff for a tracked file, the text of an untracked one;
        /// nil for an untracked file too big to read.
        public var text: String?
        /// An untracked file that is not text.
        public var isBinary: Bool

        public init(path: String, text: String?, isBinary: Bool = false) {
            self.path = path
            self.text = text
            self.isBinary = isBinary
        }
    }

    public struct Material: Equatable, Sendable {
        /// The branch, or the directory's name when HEAD is detached.
        public var subject: String
        public var directory: String
        /// Index against HEAD, one entry per file.
        public var staged: [FileChange]
        /// Working tree against the index.
        public var unstaged: [FileChange]
        public var untracked: [FileChange]

        public init(subject: String, directory: String, staged: [FileChange], unstaged: [FileChange], untracked: [FileChange]) {
            self.subject = subject
            self.directory = directory
            self.staged = staged
            self.unstaged = unstaged
            self.untracked = untracked
        }

        public var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    }

    /// How the reply to the review request ended, for the note at the top of
    /// the thread (official `codeReviewPlugin.manualReview.unreported`).
    public enum Outcome: Equatable, Sendable {
        case running
        case reported
        case unreported
    }

    /// The review thread's title.
    public static func title(for material: Material) -> String {
        "审查：\(material.subject)"
    }

    /// The request, or nil when there is nothing to review.
    public static func build(_ material: Material, budget: Int = budget) -> String? {
        guard !material.isEmpty else { return nil }
        let sections: [(title: String, label: String, files: [FileChange], untracked: Bool)] = [
            ("已暂存的改动", "已暂存", material.staged, false),
            ("未暂存的改动", "未暂存", material.unstaged, false),
            ("未跟踪的文件", "未跟踪", material.untracked, true),
        ]
        var remaining = budget
        var body = ""
        var omitted: [String] = []
        for section in sections {
            var included = ""
            for file in section.files {
                if let block = block(for: file, untracked: section.untracked), block.utf8.count <= remaining {
                    included += block
                    remaining -= block.utf8.count
                } else {
                    omitted.append("- \(section.label) `\(file.path)`")
                }
            }
            if !included.isEmpty {
                body += "\n## \(section.title)\n" + included
            }
        }
        var request = """
        请审查 `\(material.directory)`（\(material.subject)）里还没有提交的改动。

        只报告值得修的问题：缺陷、行为回归、安全隐患；不评论代码风格。需要上下文时可以读取工作目录里的文件，但不要修改任何文件，也不要运行会改变仓库的命令。

        每条发现写明：
        - 位置：`文件:行号`
        - 严重程度：高 / 中 / 低
        - 问题：错在哪里，什么情况下会出错
        - 建议的修复

        没有发现问题就直接说「没有发现问题」。最后单独一行给出结论：「结论：可以提交」或「结论：需要修改」。

        """
        request += body
        if !omitted.isEmpty {
            request += "\n## 没有附上的文件\n\n改动超过 \(budget / 1024) KB 的上限，下面这些文件没有附上，需要时请自己读取：\n"
            request += omitted.joined(separator: "\n") + "\n"
        }
        return request
    }

    /// One file's part of the request, or nil when there is nothing to show
    /// for it (an untracked file too big to read).
    private static func block(for file: FileChange, untracked: Bool) -> String? {
        let heading = "\n### `\(file.path)`\n\n"
        if file.isBinary { return heading + "（二进制文件，内容未列出）\n" }
        guard let text = file.text else { return nil }
        if untracked, text.isEmpty { return heading + "（空文件）\n" }
        return heading + fenced(text, language: untracked ? "" : "diff")
    }

    /// A code fence longer than any backtick run inside `text`, so a diff of
    /// a Markdown file cannot close it early.
    private static func fenced(_ text: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return "\(fence)\(language)\n\(body)\n\(fence)\n"
    }

    // MARK: Reading the changes

    /// Splits one `git diff` output into its files, in git's order.
    public static func splitDiff(_ diff: String) -> [FileChange] {
        var files: [FileChange] = []
        var chunk: [Substring] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            while chunk.last?.isEmpty == true { chunk.removeLast() }
            files.append(FileChange(path: path(of: chunk), text: chunk.joined(separator: "\n")))
            chunk.removeAll()
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flush()
            } else if chunk.isEmpty {
                // Nothing before the first header belongs to a file.
                continue
            }
            chunk.append(line)
        }
        flush()
        return files
    }

    /// The file one patch is about: the new name of a rename or copy,
    /// otherwise the path both sides of the header share.
    private static func path(of chunk: [Substring]) -> String {
        for line in chunk.dropFirst() {
            if line.hasPrefix("@@") { break }
            for prefix in ["rename to ", "copy to "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        let header = chunk[0]
        for prefix in ["diff --cc ", "diff --combined "] where header.hasPrefix(prefix) {
            return String(header.dropFirst(prefix.count))
        }
        // `a/P b/P`: with both sides equal the split is unambiguous even
        // when P contains spaces.
        let sides = header.dropFirst("diff --git ".count)
        if sides.hasPrefix("a/"), (sides.count - 5) % 2 == 0, sides.count > 5 {
            let length = (sides.count - 5) / 2
            let left = sides.dropFirst(2).prefix(length)
            let right = sides.dropFirst(2 + length)
            if right.hasPrefix(" b/"), right.dropFirst(3) == left { return String(left) }
        }
        for line in chunk.dropFirst() {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("+++ b/") { return String(line.dropFirst(6)) }
            if line.hasPrefix("--- a/") { return String(line.dropFirst(6)) }
        }
        return String(sides)
    }

    /// Everything not yet committed in the checkout around `directory`:
    /// staged and unstaged diffs, then untracked files' text. Untracked
    /// files are read only while they can still fit `budget`, the way `build`
    /// fills it, so a forgotten build folder is not read into memory.
    public static func collect(in directory: String, budget: Int = budget) throws -> Material {
        let root = try GitWorkingTree.repositoryRoot(of: directory)
        let staged = splitDiff(try GitWorkingTree.fullDiff(staged: true, in: root))
        let unstaged = splitDiff(try GitWorkingTree.fullDiff(staged: false, in: root))
        var remaining = budget
        for file in staged + unstaged {
            let size = file.text?.utf8.count ?? 0
            if size <= remaining { remaining -= size }
        }
        var untracked: [FileChange] = []
        for path in try GitWorkingTree.untrackedFiles(in: root) {
            let file = readUntracked(path, root: root, limit: remaining)
            if let text = file.text, text.utf8.count <= remaining { remaining -= text.utf8.count }
            untracked.append(file)
        }
        let subject: String
        if let branch = try? GitWorkingTree.branchInfo(in: root), !branch.detached {
            subject = branch.name
        } else {
            subject = (directory as NSString).lastPathComponent
        }
        return Material(subject: subject, directory: directory, staged: staged, unstaged: unstaged, untracked: untracked)
    }

    private static func readUntracked(_ path: String, root: String, limit: Int) -> FileChange {
        let full = (root as NSString).appendingPathComponent(path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: full)
        // Never followed: the link may point anywhere on the disk.
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "?"
            return FileChange(path: path, text: "符号链接，指向 \(target)")
        }
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= limit, let data = FileManager.default.contents(atPath: full) else {
            return FileChange(path: path, text: nil)
        }
        if data.contains(0) { return FileChange(path: path, text: nil, isBinary: true) }
        return FileChange(path: path, text: String(decoding: data, as: UTF8.self))
    }

    // MARK: The review thread

    /// How the reply to the thread's first message — the review request —
    /// ended. Nil for a thread that is not a review. `isStreaming` is whether
    /// this thread's reply is still running.
    public static func outcome(of conversation: Conversation, isStreaming: Bool) -> Outcome? {
        guard conversation.isCodeReview,
              let request = conversation.messages.firstIndex(where: { $0.role == .user }) else { return nil }
        let following = conversation.messages[(request + 1)...]
        let reply = following.prefix { $0.role != .user }
        let followedUp = reply.count < following.count
        if isStreaming, !followedUp { return .running }
        guard let answer = reply.last(where: { $0.role == .assistant }), answer.status != .failed,
              !answer.concatenatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unreported
        }
        return .reported
    }
}
