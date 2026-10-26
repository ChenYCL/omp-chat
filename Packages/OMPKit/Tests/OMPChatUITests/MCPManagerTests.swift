import XCTest
import OMPCore
@testable import OMPChatUI

/// The manager against real child processes: settings edits restart only the
/// servers whose launch changed, secrets come from the model's vault, and the
/// "mcp" provider follows along. A wrong diff restarts every server on a
/// rename (losing their state), or keeps running one the user switched off.
@MainActor
final class MCPManagerTests: XCTestCase {
    private static let server = #"""
    import json, os, sys
    with open(os.environ["MOCK_STARTS"], "a") as f:
        f.write("start\n")
    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "mock", "version": "1"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                {"name": "echo", "inputSchema": {"type": "object"}},
                {"name": "env", "inputSchema": {"type": "object"}}]}})
        elif method == "tools/call":
            args = msg["params"].get("arguments") or {}
            value = os.environ.get(args.get("name", ""), "<unset>") if msg["params"]["name"] == "env" else "echo"
            send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": value}]}})
    """#

    private var directory: URL!

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func starts(_ name: String) -> Int {
        let text = (try? String(contentsOf: directory.appendingPathComponent("\(name).log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func waitUntil(_ timeout: Double = 20, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("condition not met within \(timeout) s")
    }

    private func isReady(_ status: MCPServerStatus) -> Bool {
        if case .ready = status { return true }
        return false
    }

    func testSettingsEditsRestartOnlyChangedServersAndSecretsComeFromTheVault() async throws {
        let home = HostExecutor.realHomeDirectory()
        guard let python = MCPLaunchPlanner.locate("python3", path: HostExecutor.childEnvironment(home: home)["PATH"] ?? "", home: home) else {
            throw XCTSkip("python3 is not installed")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-manager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)

        let secrets = InMemorySecretStore()
        let model = ChatAppModel(
            store: InMemoryConversationStore(), secrets: secrets,
            mediaLibrary: MediaLibrary(rootURL: directory), transport: URLSessionTransport()
        )
        await model.bootstrap()
        try secrets.setSecret("vault-value", for: MCPServerConfig.vaultAccount(serverID: "a", variable: "TOKEN"))

        func config(_ id: String) -> MCPServerConfig {
            MCPServerConfig(id: id, name: id.uppercased(), command: python, args: ["-u", "-I", script.path],
                            env: ["MOCK_STARTS": directory.appendingPathComponent("\(id).log").path, "TOKEN": ""])
        }
        var settings = model.settings
        settings.mcpServers = [config("a"), config("b")]
        await model.saveSettings(settings)
        model.startMCP()
        let manager = model.mcp
        try await waitUntil { self.isReady(manager.status(of: "a")) && self.isReady(manager.status(of: "b")) }

        let provider = try XCTUnwrap(model.toolProviders["mcp"])
        let context = AgentToolContext(conversationID: UUID(), workingDirectory: nil)
        var names = await provider.tools().map(\.name)
        XCTAssertEqual(names, ["mcp__a__echo", "mcp__a__env", "mcp__b__echo", "mcp__b__env"])
        let token = try await provider.call("mcp__a__env", argumentsJSON: #"{"name":"TOKEN"}"#, context: context)
        XCTAssertEqual(token.text, "vault-value", "the secret is read from the model's vault")
        let unset = try await provider.call("mcp__b__env", argumentsJSON: #"{"name":"TOKEN"}"#, context: context)
        XCTAssertEqual(unset.text, "<unset>", "a blank variable without a vault value is not set")

        // Rename and switch a tool off: applied in place, no restart.
        settings.mcpServers[0].name = "Renamed"
        settings.mcpServers[0].disabledTools = ["env"]
        await model.saveSettings(settings)
        try await waitUntil { await provider.tools().map(\.name) == ["mcp__a__echo", "mcp__b__echo", "mcp__b__env"] }
        let source = await provider.tools().first?.source
        XCTAssertEqual(source, "MCP · Renamed")
        XCTAssertEqual(starts("a"), 1)

        // New arguments for b: b restarts, a keeps running.
        settings.mcpServers[1].args.append("--extra")
        await model.saveSettings(settings)
        try await waitUntil { self.starts("b") == 2 && self.isReady(manager.status(of: "b")) }
        XCTAssertEqual(starts("a"), 1)

        // A new vault value restarts only the server that uses it.
        try secrets.setSecret("rotated", for: MCPServerConfig.vaultAccount(serverID: "a", variable: "TOKEN"))
        manager.sync()
        try await waitUntil { self.starts("a") == 2 && self.isReady(manager.status(of: "a")) }
        let rotated = try await provider.call("mcp__a__echo", argumentsJSON: "{}", context: context)
        XCTAssertEqual(rotated.text, "echo")
        XCTAssertEqual(starts("b"), 2)

        // Switched off: stopped and its tools withdrawn.
        settings.mcpServers[0].enabled = false
        await model.saveSettings(settings)
        try await waitUntil { manager.status(of: "a") == .disabled }
        names = await provider.tools().map(\.name)
        XCTAssertEqual(names, ["mcp__b__echo", "mcp__b__env"])
        do {
            _ = try await provider.call("mcp__a__echo", argumentsJSON: "{}", context: context)
            XCTFail("a stopped server's tools must not run")
        } catch let error as MCPError {
            XCTAssertEqual(error, .unknownTool("mcp__a__echo"))
        }

        // A command that does not exist fails without retrying forever.
        settings.mcpServers.append(MCPServerConfig(id: "typo", name: "Typo", command: "no-such-mcp-command-\(UUID().uuidString.prefix(6))"))
        await model.saveSettings(settings)
        try await waitUntil {
            if case .failed(let reason, _) = manager.status(of: "typo") { return reason.contains("找不到命令") }
            return false
        }

        await manager.stopAll()
    }
}
