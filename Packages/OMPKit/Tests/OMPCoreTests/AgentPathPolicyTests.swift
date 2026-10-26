import XCTest
@testable import OMPCore

final class AgentPathPolicyTests: XCTestCase {
    private var root: URL!
    private var project: String!
    private var outside: String!

    override func setUpWithError() throws {
        // `temporaryDirectory` is under /var, itself a symlink to /private/var:
        // every comparison below crosses at least one link.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-path-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj").path
        outside = root.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: project + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: URL(fileURLWithPath: outside + "/secret.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func risk(_ raw: String, _ access: AgentPathPolicy.Access, roots: [String] = []) -> ToolRisk? {
        guard let path = AgentPathPolicy.resolve(raw, workingDirectory: project, home: "/Users/nobody") else { return nil }
        return AgentPathPolicy.risk(of: path, access: access, workingDirectory: project, readableRoots: roots)
    }

    func testResolveRelativeAbsoluteAndHome() {
        XCTAssertEqual(AgentPathPolicy.resolve("src/a.swift", workingDirectory: "/w", home: "/h"), "/w/src/a.swift")
        XCTAssertEqual(AgentPathPolicy.resolve("/etc/hosts", workingDirectory: "/w", home: "/h"), "/etc/hosts")
        XCTAssertEqual(AgentPathPolicy.resolve("~/notes.md", workingDirectory: nil, home: "/h"), "/h/notes.md")
        XCTAssertEqual(AgentPathPolicy.resolve("~", workingDirectory: nil, home: "/h"), "/h")
        XCTAssertNil(AgentPathPolicy.resolve("src/a.swift", workingDirectory: nil, home: "/h"), "没有工作目录时相对路径无法解析")
        XCTAssertNil(AgentPathPolicy.resolve("   ", workingDirectory: "/w", home: "/h"))
    }

    func testInsideWorkingDirectoryIsReadOrWrite() {
        XCTAssertEqual(risk("src", .read), .read)
        XCTAssertEqual(risk(".", .read), .read)
        XCTAssertEqual(risk("src/new/file.swift", .write), .write, "尚不存在的文件仍按其所在目录判断")
        XCTAssertEqual(risk(project + "/README.md", .write), .write)
    }

    func testDotDotEscapeIsExecute() {
        XCTAssertEqual(risk("../outside/secret.txt", .read), .execute)
        XCTAssertEqual(risk("src/../../outside/secret.txt", .write), .execute)
        XCTAssertEqual(risk("src/../README.md", .write), .write, "回到工作目录内的 .. 仍在里面")
    }

    func testSiblingWithSharedPrefixIsOutside() throws {
        let sibling = project + "2"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        XCTAssertEqual(risk(sibling + "/file", .read), .execute)
    }

    func testSymlinkPointingOutsideIsExecute() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/link.txt", withDestinationPath: outside + "/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: project + "/out", withDestinationPath: "../outside")
        XCTAssertEqual(risk("link.txt", .read), .execute)
        XCTAssertEqual(risk("link.txt", .write), .execute)
        XCTAssertEqual(risk("out/secret.txt", .read), .execute, "相对目标的目录链接也要跟随")
        XCTAssertEqual(risk("out/new.txt", .write), .execute)
    }

    func testDanglingSymlinkOutsideIsExecute() throws {
        // Writing through it would create the file outside.
        try FileManager.default.createSymbolicLink(atPath: project + "/dangling", withDestinationPath: outside + "/not-yet")
        XCTAssertEqual(risk("dangling", .write), .execute)
    }

    func testDotDotAfterSymlinkAppliesToTheTarget() throws {
        // proj/deep -> outside/a/b ; proj/deep/../../secret.txt is outside/secret.txt
        // physically, although it reads as proj/secret.txt lexically.
        try FileManager.default.createDirectory(atPath: outside + "/a/b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/deep", withDestinationPath: outside + "/a/b")
        XCTAssertEqual(risk("deep/../../secret.txt", .read), .execute)
    }

    func testSymlinkFromOutsideIntoProjectCountsAsInside() throws {
        let link = root.appendingPathComponent("shortcut").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project)
        XCTAssertEqual(risk(link + "/src", .read), .read)
        XCTAssertEqual(
            AgentPathPolicy.risk(of: project + "/src", access: .read, workingDirectory: link, readableRoots: []), .read,
            "工作目录本身是链接时按其目标判断"
        )
    }

    func testPrivateVarAliasIsInside() {
        let base: String = project
        let aliased = base.hasPrefix("/var/") ? "/private" + base : base
        XCTAssertEqual(AgentPathPolicy.risk(of: aliased + "/src", access: .write, workingDirectory: base, readableRoots: []), .write)
    }

    func testReadableRootsAllowReadsOnly() {
        XCTAssertEqual(risk(outside + "/secret.txt", .read, roots: [outside]), .read)
        XCTAssertEqual(risk(outside + "/secret.txt", .write, roots: [outside]), .execute, "可读根目录不放行写入")
        XCTAssertEqual(risk(outside + "/../proj2/x", .read, roots: [outside]), .execute)
    }

    func testNoWorkingDirectoryMakesEverythingOutside() {
        XCTAssertEqual(AgentPathPolicy.risk(of: outside + "/secret.txt", access: .read, workingDirectory: nil, readableRoots: []), .execute)
        XCTAssertEqual(AgentPathPolicy.risk(of: outside + "/secret.txt", access: .read, workingDirectory: nil, readableRoots: [outside]), .read)
    }

    func testSymlinkLoopTerminates() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/loop1", withDestinationPath: project + "/loop2")
        try FileManager.default.createSymbolicLink(atPath: project + "/loop2", withDestinationPath: project + "/loop1")
        _ = AgentPathPolicy.canonical(project + "/loop1/x")
    }
}
