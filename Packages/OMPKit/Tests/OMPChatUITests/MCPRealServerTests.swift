import XCTest
import OMPCore
@testable import OMPChatUI

/// The catalog's Filesystem entry, installed and run for real through npx in
/// a temporary folder. Skipped when npx is missing or the package cannot be
/// downloaded; never runs longer than the hard limit below.
final class MCPRealServerTests: XCTestCase {
    private static let hardLimit: Double = 240

    func testCatalogFilesystemServerReadsAndWritesInsideItsFolder() async throws {
        let home = HostExecutor.realHomeDirectory()
        let base = HostExecutor.childEnvironment(home: home)
        guard MCPLaunchPlanner.locate("npx", path: base["PATH"] ?? "", home: home) != nil else {
            throw XCTSkip("npx is not installed")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-real-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "hello from OMPChat\n".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let entry = try XCTUnwrap(MCPCatalog.entries.first { $0.id == "filesystem" })
        let config = try entry.install(values: ["directories": [folder.path]], existingIDs: [], home: home).config
        let environment = MCPLaunchPlanner.environment(base: base, config: config, secret: { _ in nil })
        let executable = try XCTUnwrap(MCPLaunchPlanner.locate(try XCTUnwrap(config.command), path: environment["PATH"] ?? "", home: home))
        let launch = MCPStdioTransport.Launch(executable: executable, arguments: config.args, environment: environment,
                                              workingDirectory: MCPLaunchPlanner.workingDirectory(for: config, home: home))
        let connection = MCPServerConnection(
            config: config,
            // First run downloads the package; later runs hit the npx cache.
            timeouts: MCPClient.Timeouts(initialize: .seconds(Self.hardLimit - 30), list: .seconds(30), call: .seconds(30)),
            policy: MCPRestartPolicy(maxRestarts: 0),
            makeTransport: { MCPStdioTransport(launch: launch, stopTree: { HostExecutor.stopTree(of: $0, escalated: $1) }) }
        )
        let started = Date()
        await connection.start()
        let state = await connection.state
        if case .failed(let reason, let log) = state {
            await connection.stop()
            let text = ([reason] + log).joined(separator: "\n")
            if ["ENOTFOUND", "ETIMEDOUT", "ECONNRESET", "EAI_AGAIN", "network", "npm error", "npm ERR"].contains(where: text.contains) {
                throw XCTSkip("the package could not be downloaded: \(reason)")
            }
            return XCTFail("the server did not start: \(text)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), Self.hardLimit)
        guard case .ready(let count) = state else { return XCTFail("unexpected state \(state)") }
        XCTAssertGreaterThan(count, 5)

        let provider = MCPToolProvider(sources: [connection])
        let specs = await provider.tools()
        let risks = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0.risk) })
        XCTAssertEqual(risks["mcp__filesystem__read_text_file"], .read, "a catalog read-only, closed-world tool needs no approval")
        XCTAssertEqual(risks["mcp__filesystem__write_file"], .write)

        let context = AgentToolContext(conversationID: UUID(), workingDirectory: folder.path)
        let read = try await provider.call("mcp__filesystem__read_text_file",
                                           argumentsJSON: #"{"path":"\#(folder.appendingPathComponent("note.txt").path)"}"#, context: context)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("hello from OMPChat"), read.text)

        let target = folder.appendingPathComponent("written.txt").path
        let write = try await provider.call("mcp__filesystem__write_file",
                                            argumentsJSON: #"{"path":"\#(target)","content":"written by the agent"}"#, context: context)
        XCTAssertFalse(write.isError, write.text)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "written by the agent")

        do {
            let outside = try await provider.call("mcp__filesystem__read_text_file", argumentsJSON: #"{"path":"/etc/hosts"}"#, context: context)
            XCTAssertTrue(outside.isError, "the server refuses paths outside its folder: \(outside.text)")
        } catch MCPError.server {
            // Refused as a protocol error instead of a tool error: also a refusal.
        }

        await connection.stop()
        let stopped = await connection.state
        XCTAssertEqual(stopped, .stopped)
    }
}
