import XCTest
@testable import OMPCore

/// AGENTS.md discovery on real folders: the wrong order lets broad rules
/// override specific ones, a missed override applies stale rules, and a
/// broken cap either floods the prompt or silently drops instructions.
final class AgentsMDLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, _ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func names(_ files: [String]) -> [String] {
        files.map { String($0.dropFirst(root.path.count + 1)) }
    }

    func testRootToLeafConcatenationWithOverridePrecedence() throws {
        _ = try folder("repo/.git")
        try write("root rules", "repo/AGENTS.md")
        try write("ignored: an override sits beside me", "repo/services/payments/AGENTS.md")
        try write("payments rules", "repo/services/payments/AGENTS.override.md")
        try write("no file here contributes", "repo/services/README.md")
        let cwd = try folder("repo/services/payments")

        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: cwd.path))
        XCTAssertEqual(names(doc.files), ["repo/AGENTS.md", "repo/services/payments/AGENTS.override.md"])
        XCTAssertEqual(doc.text, "root rules\n\npayments rules")
        XCTAssertFalse(doc.truncated)
        XCTAssertEqual(doc.projectRoot.map { ($0 as NSString).standardizingPath }, (root.appendingPathComponent("repo").path as NSString).standardizingPath)
    }

    func testFilesAboveTheRepositoryRootAreNotRead() throws {
        try write("outside the repo", "AGENTS.md")
        _ = try folder("repo/.git")
        try write("repo", "repo/AGENTS.md")
        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: try folder("repo/app").path))
        XCTAssertEqual(names(doc.files), ["repo/AGENTS.md"])
    }

    func testWorktreeGitFileMarksTheRoot() throws {
        try write("gitdir: /elsewhere", "wt/.git")
        try write("outer", "AGENTS.md")
        try write("worktree", "wt/AGENTS.md")
        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: try folder("wt/src").path))
        XCTAssertEqual(doc.text, "worktree")
    }

    func testWithoutRepositoryOnlyTheWorkingDirectoryIsRead() throws {
        try write("parent", "loose/AGENTS.md")
        try write("child", "loose/child/AGENTS.md")
        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: try folder("loose/child").path))
        XCTAssertEqual(names(doc.files), ["loose/child/AGENTS.md"])
        XCTAssertNil(doc.projectRoot)
        XCTAssertNil(AgentsMDLoader.load(workingDirectory: try folder("loose/empty").path), "parent files never apply without a repository")
    }

    func testEmptyFilesContributeNothingAndAnEmptyOverrideStillShadows() throws {
        _ = try folder("repo/.git")
        try write("  \n\n", "repo/AGENTS.md")
        try write("", "repo/pkg/AGENTS.override.md")
        try write("shadowed by the empty override", "repo/pkg/AGENTS.md")
        try write("leaf", "repo/pkg/leaf/AGENTS.md")
        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: try folder("repo/pkg/leaf").path))
        XCTAssertEqual(names(doc.files), ["repo/pkg/leaf/AGENTS.md"])
        XCTAssertEqual(doc.text, "leaf")
    }

    func testCapCutsTheCrossingFileMarksItAndSkipsTheRest() throws {
        _ = try folder("repo/.git")
        try write(String(repeating: "a", count: 60), "repo/AGENTS.md")
        // Three-byte characters: the cut must not split one.
        try write(String(repeating: "规", count: 30), "repo/mid/AGENTS.md")
        try write("never read", "repo/mid/leaf/AGENTS.md")
        let cwd = try folder("repo/mid/leaf")

        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: cwd.path, maxBytes: 100))
        XCTAssertTrue(doc.truncated)
        XCTAssertEqual(names(doc.files), ["repo/AGENTS.md", "repo/mid/AGENTS.md"])
        let pieces = doc.text.components(separatedBy: "\n\n")
        XCTAssertEqual(pieces[0], String(repeating: "a", count: 60))
        XCTAssertEqual(pieces[1], String(repeating: "规", count: 13), "40 bytes left: 13 whole characters")
        XCTAssertEqual(pieces.last, AgentsMDLoader.truncationMarker(maxBytes: 100))
        XCTAssertFalse(doc.text.contains("never read"))
    }

    func testExactFitIsNotTruncated() throws {
        try write(String(repeating: "b", count: 100), "only/AGENTS.md")
        let doc = try XCTUnwrap(AgentsMDLoader.load(workingDirectory: try folder("only").path, maxBytes: 100))
        XCTAssertFalse(doc.truncated)
        XCTAssertEqual(doc.text.count, 100)
    }

    func testMissingFolderOrNoFilesGivesNothing() throws {
        XCTAssertNil(AgentsMDLoader.load(workingDirectory: root.appendingPathComponent("absent").path))
        XCTAssertNil(AgentsMDLoader.load(workingDirectory: try folder("bare").path))
    }
}
