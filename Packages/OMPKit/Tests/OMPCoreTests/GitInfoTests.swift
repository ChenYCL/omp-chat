import XCTest
@testable import OMPCore

final class GitInfoTests: XCTestCase {
    func testReadsBranchFromGitHead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-git-\(UUID().uuidString)", isDirectory: true)
        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/align\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(GitInfo.branch(at: root), "feature/align")
    }

    func testNilOutsideRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GitInfo.branch(at: root))
    }

    func testTildifiesHome() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        XCTAssertEqual(GitInfo.tildified(home.path), "~")
        XCTAssertTrue(GitInfo.tildified(home.appendingPathComponent("x").path).hasPrefix("~/x"))
    }
}
