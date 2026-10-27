import XCTest
@testable import OMPCore

final class FileReferenceTests: XCTestCase {
    // MARK: Detection

    func testPathsWithAndWithoutLocations() {
        XCTAssertEqual(FileReference.parse("src/a.swift"), FileReference(path: "src/a.swift"))
        XCTAssertEqual(FileReference.parse("./b/c.ts"), FileReference(path: "./b/c.ts"))
        XCTAssertEqual(FileReference.parse("../x/y.swift"), FileReference(path: "../x/y.swift"))
        XCTAssertEqual(FileReference.parse("/usr/bin/git"), FileReference(path: "/usr/bin/git"))
        XCTAssertEqual(FileReference.parse("~/notes/todo.md"), FileReference(path: "~/notes/todo.md"))
        XCTAssertEqual(FileReference.parse("Package.swift"), FileReference(path: "Package.swift"))
        XCTAssertEqual(FileReference.parse(".gitignore"), FileReference(path: ".gitignore"))
        XCTAssertEqual(FileReference.parse(".env.local"), FileReference(path: ".env.local"))
        XCTAssertEqual(FileReference.parse("Makefile"), FileReference(path: "Makefile"))
        XCTAssertEqual(FileReference.parse("Sources/OMPCore"), FileReference(path: "Sources/OMPCore"))
        XCTAssertEqual(FileReference.parse("文档/说明.md"), FileReference(path: "文档/说明.md"))
        XCTAssertEqual(FileReference.parse(" src/a.swift "), FileReference(path: "src/a.swift"))
    }

    func testLineAndColumnSuffixes() {
        XCTAssertEqual(FileReference.parse("src/a.swift:12"), FileReference(path: "src/a.swift", line: 12))
        XCTAssertEqual(FileReference.parse("src/a.swift:12:5"), FileReference(path: "src/a.swift", line: 12, column: 5))
        XCTAssertEqual(FileReference.parse("src/a.swift:12-20"), FileReference(path: "src/a.swift", line: 12))
        XCTAssertEqual(FileReference.parse("src/a.swift#L12"), FileReference(path: "src/a.swift", line: 12))
        XCTAssertEqual(FileReference.parse("src/a.swift#L12C3"), FileReference(path: "src/a.swift", line: 12, column: 3))
        XCTAssertEqual(FileReference.parse("src/a.swift#L12-L20"), FileReference(path: "src/a.swift", line: 12))
        XCTAssertEqual(FileReference.parse("a.swift:7"), FileReference(path: "a.swift", line: 7))
    }

    func testMalformedLocationsAreNotReferences() {
        XCTAssertNil(FileReference.parse("src/a.swift:0"), "行号从 1 开始")
        XCTAssertNil(FileReference.parse("src/a.swift:abc"))
        XCTAssertNil(FileReference.parse("src/a.swift:12:5:9"))
        XCTAssertNil(FileReference.parse("src/a.swift#section"))
        XCTAssertNil(FileReference.parse("src/a.swift#L"))
        XCTAssertNil(FileReference.parse(":12"))
    }

    func testURLsEmailsGlobsVersionsAndWordsAreNotPaths() {
        let negatives = [
            "https://example.com/a.swift", "http://localhost:8080", "file:///Users/me/a.swift", "//cdn.example.com/a.js",
            "mailto:me@example.com", "me@example.com", "@Observable",
            "*.swift", "src/**/*.ts", "file?.txt", "{a,b}.ts", "[id].tsx",
            "1.2.3", "v1.2.3", "v2.0", "2.0", "swift-tools-version:6.0",
            "e.g.", "i.e.", "etc.", "model.stop", "self.view", "os.path", "www.example.com", "example.com",
            "localhost:8080", "README", "~", "~user/a.txt", "/", "2024/10/27", "a/b.", "x = a.b", "let a = 1",
            ".swift", "#L12", "",
        ]
        for text in negatives {
            XCTAssertNil(FileReference.parse(text), "不该当成路径：\(text)")
        }
    }

    func testWrittenAbsolute() {
        XCTAssertTrue(FileReference(path: "/etc/hosts").isWrittenAbsolute)
        XCTAssertTrue(FileReference(path: "~/a.txt").isWrittenAbsolute)
        XCTAssertFalse(FileReference(path: "src/a.swift").isWrittenAbsolute)
        XCTAssertFalse(FileReference(path: "../a.swift").isWrittenAbsolute)
    }

    // MARK: Mentions in rendered text

    private func mentions(_ markdown: String) throws -> [(text: String, reference: FileReference)] {
        let text = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return FileReference.mentions(in: text).map { (String(text[$0.range].characters), $0.reference) }
    }

    func testCodeSpansAndLinkTargetsAreFoundInOrder() throws {
        let found = try mentions("先看 [入口](Sources/App/main.swift#L3)，再看 `src/a.swift:12` 和 `npm install`。")
        XCTAssertEqual(found.map(\.text), ["入口", "src/a.swift:12"])
        XCTAssertEqual(found.map(\.reference), [
            FileReference(path: "Sources/App/main.swift", line: 3),
            FileReference(path: "src/a.swift", line: 12),
        ])
    }

    func testURLLinksAndPlainTextAreLeftAlone() throws {
        let found = try mentions("见 [文档](https://example.com/a.md)、src/plain.swift 和 `v1.2.3`")
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testCodeInsideALinkBelongsToTheLinkTarget() throws {
        let found = try mentions("[`helper.swift`](https://example.com/helper.swift)")
        XCTAssertTrue(found.isEmpty, "链接指向网址，里面的代码不能再当成文件")
    }

    func testPercentEncodedLinkTargetIsDecoded() throws {
        let found = try mentions("[说明](%E6%96%87%E6%A1%A3/a.md)")
        XCTAssertEqual(found.map(\.reference), [FileReference(path: "文档/a.md")])
    }

    // MARK: Lines

    func testLineRangesAreClampedAndExcludeTheBreak() {
        let text = "one\ntwo\n\nfour"
        XCTAssertEqual(FileReference.utf16Range(ofLine: 1, in: text), NSRange(location: 0, length: 3))
        XCTAssertEqual(FileReference.utf16Range(ofLine: 2, in: text), NSRange(location: 4, length: 3))
        XCTAssertEqual(FileReference.utf16Range(ofLine: 3, in: text), NSRange(location: 8, length: 0))
        XCTAssertEqual(FileReference.utf16Range(ofLine: 4, in: text), NSRange(location: 9, length: 4))
        XCTAssertEqual(FileReference.utf16Range(ofLine: 99, in: text), NSRange(location: 9, length: 4), "超过末行就停在末行")
        XCTAssertEqual(FileReference.utf16Range(ofLine: 0, in: text), NSRange(location: 0, length: 3))
        XCTAssertEqual(FileReference.utf16Range(ofLine: 2, in: "😀\n第二行"), NSRange(location: 3, length: 3), "UTF-16 偏移")
    }
}

final class FileReferenceResolverTests: XCTestCase {
    private var root: URL!
    private var workspace: String!

    override func setUpWithError() throws {
        // Real path: /var is a symlink to /private/var.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fileref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: AgentPathPolicy.canonical(base.path))
        workspace = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: workspace + "/src", withIntermediateDirectories: true)
        try "let a = 1\n".write(toFile: workspace + "/src/a.swift", atomically: true, encoding: .utf8)
        try "secret\n".write(toFile: root.appendingPathComponent("outside.txt").path, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolver(home: String = "/home/me") -> FileReferenceResolver {
        FileReferenceResolver(home: home)
    }

    func testRelativeReferenceResolvesAgainstTheWorkingDirectory() throws {
        let resolved = try XCTUnwrap(resolver().resolve(FileReference(path: "src/a.swift", line: 2), workingDirectory: workspace))
        XCTAssertEqual(resolved.path, workspace + "/src/a.swift")
        XCTAssertEqual(resolved.kind, .file)
        XCTAssertEqual(resolved.reference.line, 2)
        XCTAssertEqual(resolver().resolve(FileReference(path: "./src"), workingDirectory: workspace)?.kind, .directory)
        XCTAssertEqual(
            resolver().resolve(FileReference(path: "src/../src/./a.swift"), workingDirectory: workspace)?.path,
            workspace + "/src/a.swift", "`.` 和 `..` 按文字规范化"
        )
    }

    func testMissingFilesAndRelativePathsWithoutADirectoryDoNotResolve() {
        XCTAssertNil(resolver().resolve(FileReference(path: "src/missing.swift"), workingDirectory: workspace))
        XCTAssertNil(resolver().resolve(FileReference(path: "src/a.swift"), workingDirectory: nil))
        XCTAssertNil(resolver().resolve(FileReference(path: "src/a.swift"), workingDirectory: ""))
    }

    func testDotDotOutOfTheWorkingDirectoryIsRefused() {
        XCTAssertNil(resolver().resolve(FileReference(path: "../outside.txt"), workingDirectory: workspace))
        XCTAssertNil(resolver().resolve(FileReference(path: "src/../../outside.txt"), workingDirectory: workspace))
        XCTAssertNil(FileReferenceResolver.absolutePath(
            of: FileReference(path: "../outside.txt"), workingDirectory: workspace, home: "/home/me"
        ), "只凭文字就能判定，不用碰磁盘")
    }

    func testSymlinkOutOfTheWorkingDirectoryIsRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: workspace + "/escape", withDestinationPath: root.path)
        try FileManager.default.createSymbolicLink(
            atPath: workspace + "/link.txt", withDestinationPath: root.appendingPathComponent("outside.txt").path
        )
        XCTAssertNil(resolver().resolve(FileReference(path: "escape/outside.txt"), workingDirectory: workspace))
        XCTAssertNil(resolver().resolve(FileReference(path: "link.txt"), workingDirectory: workspace))
        // A link that stays inside is fine.
        try FileManager.default.createSymbolicLink(atPath: workspace + "/alias", withDestinationPath: workspace + "/src")
        XCTAssertEqual(resolver().resolve(FileReference(path: "alias/a.swift"), workingDirectory: workspace)?.kind, .file)
    }

    func testWrittenAbsoluteReferencesMayPointOutside() throws {
        let outside = root.appendingPathComponent("outside.txt").path
        XCTAssertEqual(resolver().resolve(FileReference(path: outside), workingDirectory: workspace)?.path, outside)
        XCTAssertEqual(resolver().resolve(FileReference(path: outside), workingDirectory: nil)?.path, outside)
        let viaHome = resolver(home: root.path).resolve(FileReference(path: "~/outside.txt"), workingDirectory: workspace)
        XCTAssertEqual(viaHome?.path, outside, "~ 展开成 home")
    }

    func testEachPathIsCheckedOnDiskOnce() {
        let calls = Counter()
        let resolver = FileReferenceResolver(home: "/home/me") { path, _ in
            calls.add(path)
            return path.hasSuffix("a.swift") ? .file : nil
        }
        for _ in 0..<5 {
            XCTAssertNotNil(resolver.resolve(FileReference(path: "src/a.swift", line: 1), workingDirectory: "/w"))
            XCTAssertNil(resolver.resolve(FileReference(path: "src/b.swift"), workingDirectory: "/w"))
        }
        XCTAssertNotNil(resolver.resolve(FileReference(path: "src/a.swift", line: 40), workingDirectory: "/w"),
                        "换一个行号还是同一个路径")
        XCTAssertEqual(calls.values, ["/w/src/a.swift", "/w/src/b.swift"])

        // Another directory is another question.
        XCTAssertNotNil(resolver.resolve(FileReference(path: "src/a.swift"), workingDirectory: "/v"))
        XCTAssertEqual(calls.values.count, 3)
    }

    func testForgettingMissingPathsChecksOnlyThoseAgain() {
        let calls = Counter()
        let created = Counter()
        let resolver = FileReferenceResolver(home: "/home/me") { path, _ in
            calls.add(path)
            return path.hasSuffix("a.swift") || created.values.contains(path) ? .file : nil
        }
        XCTAssertNotNil(resolver.resolve(FileReference(path: "a.swift"), workingDirectory: "/w"))
        XCTAssertNil(resolver.resolve(FileReference(path: "new.swift"), workingDirectory: "/w"))
        created.add("/w/new.swift")
        XCTAssertNil(resolver.resolve(FileReference(path: "new.swift"), workingDirectory: "/w"), "记住的答案")

        resolver.forgetMissing()

        XCTAssertNotNil(resolver.resolve(FileReference(path: "new.swift"), workingDirectory: "/w"))
        XCTAssertNotNil(resolver.resolve(FileReference(path: "a.swift"), workingDirectory: "/w"))
        XCTAssertEqual(calls.values, ["/w/a.swift", "/w/new.swift", "/w/new.swift"])
    }

    func testProbeIsAskedToStayInsideOnlyForRelativeReferences() {
        let roots = Counter()
        let resolver = FileReferenceResolver(home: "/home/me") { _, root in
            roots.add(root ?? "nil")
            return .file
        }
        _ = resolver.resolve(FileReference(path: "src/a.swift"), workingDirectory: "/w/./repo/")
        _ = resolver.resolve(FileReference(path: "/etc/hosts"), workingDirectory: "/w/repo")
        _ = resolver.resolve(FileReference(path: "~/a.txt"), workingDirectory: "/w/repo")
        XCTAssertEqual(roots.values, ["/w/repo", "nil", "nil"])
    }

    // MARK: Copying contents

    func testReadTextRefusesLargeBinaryAndFolders() throws {
        let path = workspace + "/src/a.swift"
        XCTAssertEqual(try FileReference.readText(at: path, limit: 10), "let a = 1\n")
        XCTAssertThrowsError(try FileReference.readText(at: path, limit: 9)) { error in
            XCTAssertEqual(error as? FileReference.ReadFailure, .tooLarge(path: path, limit: 9))
        }
        let binary = workspace + "/blob.bin"
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: binary))
        XCTAssertThrowsError(try FileReference.readText(at: binary, limit: 100)) { error in
            XCTAssertEqual(error as? FileReference.ReadFailure, .notText(binary))
        }
        XCTAssertThrowsError(try FileReference.readText(at: workspace + "/src", limit: 100)) { error in
            XCTAssertEqual(error as? FileReference.ReadFailure, .directory(workspace + "/src"))
        }
        XCTAssertThrowsError(try FileReference.readText(at: workspace + "/nope", limit: 100)) { error in
            XCTAssertEqual(error as? FileReference.ReadFailure, .missing(workspace + "/nope"))
        }
    }
}

/// Records values from the resolver's `@Sendable` probe.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func add(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
}
