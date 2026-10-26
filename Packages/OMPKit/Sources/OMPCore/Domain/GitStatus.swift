import Foundation

/// `git status --porcelain -z`, parsed.
///
/// The `-z` form is the only one that is safe to split: entries are
/// NUL-terminated and paths are never quoted. Plain porcelain prints a name
/// with spaces as `"with space.txt"` and a Chinese one as
/// `"\344\270\255…"`, and a rename as `old -> new` — none of which can be passed
/// back to `git diff -- <path>`. Here a rename carries its source as a
/// separate field.
public enum GitStatus {
    public struct Entry: Equatable, Sendable {
        /// The raw XY columns, blanks kept: X is the index (staged) side, Y
        /// the worktree side. `" M"` and `"M "` are different changes.
        public var xy: String
        /// Path relative to the repository root; the new path for a rename.
        public var path: String
        /// Source path of a rename or copy.
        public var originalPath: String?

        public init(xy: String, path: String, originalPath: String? = nil) {
            self.xy = xy
            self.path = path
            self.originalPath = originalPath
        }

        /// The XY code with blanks trimmed: `M`, `A`, `D`, `R`, `MM`, `??`.
        public var code: String {
            let code = xy.trimmingCharacters(in: .whitespaces)
            return code.isEmpty ? "?" : code
        }

        /// X: what the index holds against HEAD.
        public var index: Character { xy.first ?? " " }
        /// Y: what the working tree holds against the index.
        public var worktree: Character { xy.dropFirst().first ?? " " }
    }

    /// `--untracked-files=all` lists every new file on its own row instead of
    /// folding a new directory into `dir/`, which could be neither diffed nor
    /// staged file by file.
    public static let arguments = ["status", "--porcelain", "-z", "--untracked-files=all"]

    public static func parse(_ output: String) -> [Entry] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var entries: [Entry] = []
        while let field = fields.popFirst() {
            // "XY path": two status letters, a space, then the path.
            guard field.count >= 4 else { continue }
            let xy = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            // Renames and copies are followed by their source path.
            let original = xy.contains("R") || xy.contains("C") ? fields.popFirst() : nil
            entries.append(Entry(xy: xy, path: path, originalPath: original))
        }
        return entries
    }
}
