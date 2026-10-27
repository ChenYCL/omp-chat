import Foundation

/// A path an assistant message mentions — an inline code span such as
/// `src/a.swift:12`, or a link target — which Codex turns into something you
/// can open (official `markdown.fileReference.*`).
///
/// Detection is textual and deliberately narrow: URLs, emails, globs,
/// version numbers and `a.b` words (`e.g.`, `model.stop`) are not paths.
/// Whether the path exists, and whether it stays inside the thread's working
/// directory, needs the disk; that is `FileReferenceResolver`'s job.
public struct FileReference: Hashable, Sendable {
    /// The path as written, location suffix removed.
    public var path: String
    /// 1-based, from `:12`, `:12:5` or `#L12`.
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// `/…` or `~/…`: the writer named the place outright, so it may lie
    /// outside the working directory.
    public var isWrittenAbsolute: Bool { path.hasPrefix("/") || path.hasPrefix("~/") }

    /// The reference a whole code span or link target makes, or nil when it
    /// is not a path.
    public static func parse(_ candidate: String) -> FileReference? {
        let text = candidate.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= 1024, !text.contains("://") else { return nil }
        let located = splitLocation(text)
        guard isPathLike(located.path) else { return nil }
        return located
    }

    /// One reference in rendered text, with the characters that show it.
    public struct Mention {
        public var range: Range<AttributedString.Index>
        public var reference: FileReference
    }

    /// Every reference in `text` (inline markdown already parsed into an
    /// `AttributedString`), in reading order: each link whose target is a
    /// path, and each inline code span outside a link that is one.
    public static func mentions(in text: AttributedString) -> [Mention] {
        var found: [Mention] = []
        for (link, range) in text.runs[\.link] {
            guard let link else { continue }
            let raw = link.relativeString
            if let reference = parse(raw.removingPercentEncoding ?? raw) {
                found.append(Mention(range: range, reference: reference))
            }
        }
        for (intent, range) in text.runs[\.inlinePresentationIntent] {
            guard let intent, intent.contains(.code) else { continue }
            // A code span that is a link's text belongs to the link's target.
            guard !text[range].runs[\.link].contains(where: { $0.0 != nil }) else { continue }
            if let reference = parse(String(text[range].characters)) {
                found.append(Mention(range: range, reference: reference))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The UTF-16 range of 1-based `line` in `text`, without its line break;
    /// clamped to the first and last line.
    public static func utf16Range(ofLine line: Int, in text: String) -> NSRange {
        let string = text as NSString
        var start = 0
        var current = 1
        while current < line {
            let next = string.range(of: "\n", options: [], range: NSRange(location: start, length: string.length - start))
            guard next.location != NSNotFound else { break }
            start = next.location + 1
            current += 1
        }
        let rest = NSRange(location: start, length: string.length - start)
        let end = string.range(of: "\n", options: [], range: rest)
        return NSRange(location: start, length: (end.location == NSNotFound ? string.length : end.location) - start)
    }

    /// Why `readText` refused.
    public enum ReadFailure: Error, Equatable, Sendable {
        case missing(String)
        case directory(String)
        case tooLarge(path: String, limit: Int)
        case notText(String)

        public var message: String {
            switch self {
            case .missing(let path): return "“\(path)”不存在"
            case .directory(let path): return "“\(path)”是文件夹，没有内容可拷贝"
            case .tooLarge(let path, let limit): return "“\((path as NSString).lastPathComponent)”超过 \(limit / 1024 / 1024) MB，没有拷贝"
            case .notText(let path): return "“\((path as NSString).lastPathComponent)”不是文本文件，没有拷贝"
            }
        }
    }

    /// The text of the file at `path` for 拷贝文件内容. Reads at most one
    /// byte past `limit`, so a larger file is refused without loading it, and
    /// refuses a file that is not text.
    public static func readText(at path: String, limit: Int) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw ReadFailure.missing(path) }
        guard !isDirectory.boolValue else { throw ReadFailure.directory(path) }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ReadFailure.missing(path) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else { throw ReadFailure.tooLarge(path: path, limit: limit) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ReadFailure.notText(path) }
        return text
    }

    // MARK: Detection

    /// Splits `:12`, `:12:5`, `:12-20` or `#L12`, `#L12C5`, `#L12-L20` off the
    /// end. Anything else stays part of the path.
    private static func splitLocation(_ text: String) -> FileReference {
        if let hash = text.lastIndex(of: "#") {
            let fragment = text[text.index(after: hash)...]
            if fragment.first == "L", let (line, column) = fragmentLocation(fragment.dropFirst()) {
                return FileReference(path: String(text[..<hash]), line: line, column: column)
            }
            return FileReference(path: text)
        }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count >= 2, let line = lineNumber(pieces[1]) else { return FileReference(path: text) }
        switch pieces.count {
        case 2:
            return FileReference(path: String(pieces[0]), line: line)
        case 3:
            guard let column = positive(pieces[2]) else { return FileReference(path: text) }
            return FileReference(path: String(pieces[0]), line: line, column: column)
        default:
            return FileReference(path: text)
        }
    }

    /// `12`, `12C5`, `12-L20` or `12-20` after `#L`.
    private static func fragmentLocation(_ fragment: Substring) -> (Int, Int?)? {
        let digits = fragment.prefix(while: isDigit)
        guard let line = positive(digits) else { return nil }
        let rest = fragment[digits.endIndex...]
        if rest.isEmpty { return (line, nil) }
        if rest.first == "C", let column = positive(rest.dropFirst()) { return (line, column) }
        if rest.first == "-" {
            let end = rest.dropFirst().drop { $0 == "L" }
            if positive(end) != nil { return (line, nil) }
        }
        return nil
    }

    /// `12` or the start of a range `12-20`.
    private static func lineNumber(_ piece: Substring) -> Int? {
        if let dash = piece.firstIndex(of: "-") {
            guard positive(piece[piece.index(after: dash)...]) != nil else { return nil }
            return positive(piece[..<dash])
        }
        return positive(piece)
    }

    private static func isDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }

    private static func positive(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(isDigit), let value = Int(digits), value > 0 else {
            return nil
        }
        return value
    }

    /// Letters, digits and the punctuation file names use; everything that
    /// marks a glob (`*?[]{}`), an email (`@`), a URL (`:`, `?`, `#`, `%`) or
    /// code (`=`, `;`, `,`, quotes) is out.
    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_-./~+()".contains(character)
    }

    private static func isPathLike(_ path: String) -> Bool {
        guard !path.isEmpty, path.allSatisfy(isPathCharacter), path.contains(where: \.isLetter) else { return false }
        // `~` only as the home directory; `//` is a protocol-relative URL.
        if path.dropFirst().contains("~") || (path.first == "~" && !path.hasPrefix("~/")) { return false }
        if path.contains("//") { return false }
        if path.contains("/") {
            // A path ending in `.` (`a/b.`) is a sentence, not a file.
            return path.split(separator: "/").allSatisfy { $0 == "." || $0 == ".." || !$0.hasSuffix(".") }
        }
        return isFileName(path)
    }

    /// A bare name counts only when it looks like a file: a known extension
    /// (`Package.swift`), a dotfile (`.gitignore`) or a well-known
    /// extensionless name (`Makefile`). That keeps `e.g.`, `model.stop` and
    /// `v1.2.3` out.
    private static func isFileName(_ name: String) -> Bool {
        if wellKnownNames.contains(name) { return true }
        guard let dot = name.lastIndex(of: ".") else { return false }
        let stem = name[..<dot]
        let fileExtension = name[name.index(after: dot)...].lowercased()
        if stem.isEmpty {
            // `.gitignore`, but not `.swift` used to mean "Swift files".
            return !fileExtension.isEmpty && !knownExtensions.contains(fileExtension)
                && fileExtension.first?.isLetter == true
        }
        if stem.hasPrefix("."), stem.count > 1 { return !fileExtension.isEmpty }
        return stem.contains(where: \.isLetter) && knownExtensions.contains(fileExtension)
    }

    private static let wellKnownNames: Set<String> = [
        "Makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Gemfile", "Podfile", "Rakefile",
        "Procfile", "Brewfile", "Justfile", "Vagrantfile", "Jenkinsfile", "LICENSE", "LICENCE", "COPYING",
    ]

    private static let knownExtensions: Set<String> = [
        // Apple
        "swift", "m", "mm", "h", "hpp", "hh", "c", "cc", "cpp", "cxx", "plist", "entitlements", "xcconfig",
        "pbxproj", "storyboard", "xib", "strings", "stringsdict", "xcstrings", "xcprivacy", "modulemap", "resolved",
        // Other languages
        "cs", "java", "kt", "kts", "scala", "groovy", "gradle", "go", "rs", "py", "pyi", "rb", "php", "pl", "pm",
        "lua", "r", "dart", "ex", "exs", "erl", "hs", "ml", "mli", "fs", "fsx", "clj", "cljs", "elm", "zig",
        "nim", "sol", "asm", "s", "wasm", "ipynb",
        // Web
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "vue", "svelte", "astro", "html", "htm", "css",
        "scss", "sass", "less",
        // Data and config
        "json", "jsonc", "json5", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "csv", "tsv",
        "sql", "graphql", "gql", "proto", "properties", "lock", "nix", "tf", "hcl", "prisma", "cmake", "mk",
        // Text
        "md", "mdx", "markdown", "txt", "rst", "adoc", "tex", "log", "diff", "patch",
        // Scripts
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        // Assets
        "svg", "png", "jpg", "jpeg", "gif", "webp", "pdf", "ico",
    ]
}

/// Where references point and whether they are there. Each (working
/// directory, path) is checked on disk once and remembered, so rendering a
/// message again costs a dictionary lookup.
public final class FileReferenceResolver: @unchecked Sendable {
    public enum Kind: Hashable, Sendable {
        case file
        case directory
    }

    /// A reference that exists.
    public struct Resolved: Hashable, Sendable {
        public var reference: FileReference
        /// Absolute: `~` expanded, `.` and `..` applied.
        public var path: String
        public var kind: Kind

        public init(reference: FileReference, path: String, kind: Kind) {
            self.reference = reference
            self.path = path
            self.kind = kind
        }
    }

    /// The disk check: what the absolute `path` is, or nil when it is
    /// missing — or, with a `root`, when it is not physically inside it.
    public typealias Probe = @Sendable (_ path: String, _ root: String?) -> Kind?

    private enum Answer {
        case missing
        case found(Kind)
    }

    private struct Key: Hashable {
        var directory: String
        var path: String
    }

    /// Beyond this many remembered paths the memory starts over.
    private static let capacity = 4096

    private let home: String
    private let probe: Probe
    private let lock = NSLock()
    private var answers: [Key: Answer] = [:]

    public init(home: String, probe: @escaping Probe = FileReferenceResolver.diskProbe) {
        self.home = home
        self.probe = probe
    }

    /// The existing file or directory `reference` names, or nil. A relative
    /// reference resolves against `workingDirectory` and must stay inside
    /// it, symlinks included; only a reference written absolute may point
    /// elsewhere.
    public func resolve(_ reference: FileReference, workingDirectory: String?) -> Resolved? {
        guard let path = Self.absolutePath(of: reference, workingDirectory: workingDirectory, home: home) else {
            return nil
        }
        let key = Key(directory: workingDirectory ?? "", path: reference.path)
        lock.lock()
        let known = answers[key]
        lock.unlock()
        let answer: Answer
        if let known {
            answer = known
        } else {
            let root = reference.isWrittenAbsolute ? nil : workingDirectory.map(Self.normalized)
            answer = probe(path, root).map(Answer.found) ?? .missing
            lock.lock()
            if answers.count >= Self.capacity { answers.removeAll() }
            answers[key] = answer
            lock.unlock()
        }
        guard case .found(let kind) = answer else { return nil }
        return Resolved(reference: reference, path: path, kind: kind)
    }

    /// Forgets every path found missing: a tool may just have created it.
    public func forgetMissing() {
        lock.lock()
        answers = answers.filter {
            if case .found = $0.value { return true }
            return false
        }
        lock.unlock()
    }

    /// The absolute path `reference` names, judged on the text alone: nil
    /// for a relative reference without a working directory, or one whose
    /// `..` climbs out of it.
    public static func absolutePath(of reference: FileReference, workingDirectory: String?, home: String) -> String? {
        let path = reference.path
        if path.hasPrefix("~/") { return normalized(home + "/" + path.dropFirst(2)) }
        if path.hasPrefix("/") { return normalized(path) }
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let base = normalized(workingDirectory)
        let joined = normalized(base + "/" + path)
        guard joined == base || joined.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
        return joined
    }

    /// `.` and empty components dropped, `..` applied, without touching the
    /// disk (`standardizingPath` consults it for `/private`).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The real check: exists (following symlinks) and, when `root` is
    /// given, lies inside it physically.
    public static let diskProbe: Probe = { path, root in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if let root, !AgentPathPolicy.isInside(path, root: root) { return nil }
        return isDirectory.boolValue ? .directory : .file
    }
}

extension FileReference.ReadFailure: LocalizedError {
    public var errorDescription: String? { message }
}
