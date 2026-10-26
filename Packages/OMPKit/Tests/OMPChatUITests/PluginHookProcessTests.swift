import XCTest
@testable import OMPCore
@testable import OMPChatUI

/// Plugin hooks run for real (zsh, `HostExecutor.runCommand`) through the
/// model: untrusted hooks must never run, a blocking hook must stop the call
/// with its message, a hung hook must not hang the call.
@MainActor
final class PluginHookProcessTests: XCTestCase {
    private var root: URL!
    private var work: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-hooks-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeModel() async -> ChatAppModel {
        let model = ChatAppModel(
            store: InMemoryConversationStore(), secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: root.appendingPathComponent("media")), transport: URLSessionTransport()
        )
        await model.bootstrap()
        model.pluginStore = PluginStore(root: root.appendingPathComponent("store"))
        model.skillsHome = nil
        model.reloadPlugins()
        return model
    }

    /// Installs a plugin whose `hooks/hooks.json` holds `groups` for `event`.
    private func install(_ model: ChatAppModel, name: String = "guard", event: String = "PreToolUse", groups: [[String: Any]], trust: Bool = true) throws {
        let folder = root.appendingPathComponent("src/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        try Data(#"{"name": "\#(name)", "version": "1.0.0"}"#.utf8).write(to: folder.appendingPathComponent(".codex-plugin/plugin.json"))
        try JSONSerialization.data(withJSONObject: ["hooks": [event: groups]]).write(to: folder.appendingPathComponent("hooks/hooks.json"))
        try model.confirmPluginInstall(try model.preparePluginInstall(folder: folder.path))
        if trust { try model.setPluginHooksTrusted(true, id: name) }
    }

    private func group(_ command: String, matcher: String? = nil, timeout: Int? = nil) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command]
        if let timeout { handler["timeout"] = timeout }
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private func thread(_ model: ChatAppModel) -> UUID {
        let conversation = model.newConversation()
        model.updateWorkingDirectory(conversation.id, work.path)
        return conversation.id
    }

    private func dataFile(_ model: ChatAppModel, _ name: String, plugin: String = "guard") throws -> String? {
        let folder = try XCTUnwrap(model.installedPlugins.first { $0.id == plugin }).dataDirectory
        return try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8)
    }

    private let shell = #"{"command":"rm -rf build","timeout_seconds":5}"#

    func testHooksStayOffUntilTrustedAndWhilePluginIsDisabled() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, groups: [group(#"touch "$PLUGIN_DATA/ran"; echo "blocked by policy" >&2; exit 2"#)], trust: false)

        let untrusted = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "c1")
        XCTAssertEqual(untrusted, .allow(context: nil, updatedArgumentsJSON: nil))
        XCTAssertNil(try dataFile(model, "ran"), "an untrusted hook never runs")
        XCTAssertNil(model.toolHooks, "nothing to wire into the loop")

        try model.setPluginHooksTrusted(true, id: "guard")
        let trusted = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "c2")
        XCTAssertEqual(trusted, .block("blocked by policy"))
        XCTAssertNotNil(try dataFile(model, "ran"))

        try model.setPluginEnabled(false, id: "guard")
        let disabled = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "c3")
        XCTAssertEqual(disabled, .allow(context: nil, updatedArgumentsJSON: nil))
    }

    func testBlockByJSONReachesTheAgentLoop() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, groups: [group(#"printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Destructive command blocked by hook."}}'"#, matcher: "Bash")])
        let hooks = try XCTUnwrap(model.toolHooks)
        let spec = AgentToolSpec(name: "shell", description: "", parametersJSON: "{}", risk: .execute, source: "内置")
        let decision = await hooks.preToolUse(ToolCall(id: "c1", name: "shell", argumentsJSON: shell), spec, model.toolContext(for: id))
        XCTAssertEqual(decision, .block("Destructive command blocked by hook."))
    }

    func testHungHookTimesOutAndTheCallGoesOn() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, groups: [group("sleep 30", timeout: 1)])
        let started = ContinuousClock.now
        let outcome = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "c1")
        XCTAssertEqual(outcome, .allow(context: nil, updatedArgumentsJSON: nil))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "the 1 s timeout, plus the 2 s grace before SIGKILL")
        let record = try XCTUnwrap(model.hookRunLog.last)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.message, "钩子超时（1 秒）")
    }

    func testMatcherPicksTheToolAndEditsAreApplyPatch() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, groups: [
            group(#"echo "bash hook" >&2; exit 2"#, matcher: "Bash"),
            group(#"cat > "$PLUGIN_DATA/edit.json"; echo "edit hook" >&2; exit 2"#, matcher: "Edit|Write"),
        ])
        let bash = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "c1")
        XCTAssertEqual(bash, .block("bash hook"))

        let edit = await model.runToolHooks(
            event: .preToolUse, toolName: "edit_file",
            argumentsJSON: #"{"path":"a.txt","old_string":"old","new_string":"new"}"#, conversationID: id, callID: "c2"
        )
        XCTAssertEqual(edit, .block("edit hook"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try dataFile(model, "edit.json")).utf8)) as? [String: Any])
        XCTAssertEqual(payload["tool_name"] as? String, "apply_patch")
        let input = try XCTUnwrap(payload["tool_input"] as? [String: Any])
        XCTAssertEqual(input["command"] as? String, "*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch")
        XCTAssertEqual(input["path"] as? String, "a.txt")

        let read = await model.runToolHooks(event: .preToolUse, toolName: "read_file", argumentsJSON: #"{"path":"a.txt"}"#, conversationID: id, callID: "c3")
        XCTAssertEqual(read, .allow(context: nil, updatedArgumentsJSON: nil), "Codex hooks only shell, edits and MCP calls")
    }

    func testStdinPayloadEnvironmentAndWorkingDirectory() async throws {
        let model = await makeModel()
        let id = thread(model)
        model.setPermissionMode(.auto, for: id)
        try install(model, groups: [group(#"cat > "$PLUGIN_DATA/payload.json"; printf '%s' "$PLUGIN_ROOT" > "$PLUGIN_DATA/root.txt"; pwd -P > "$PLUGIN_DATA/pwd.txt""#)])
        _ = await model.runToolHooks(event: .preToolUse, toolName: "shell", argumentsJSON: shell, conversationID: id, callID: "call_42")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try dataFile(model, "payload.json")).utf8)) as? [String: Any])
        XCTAssertEqual(payload["session_id"] as? String, id.uuidString)
        XCTAssertEqual(payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(payload["cwd"] as? String, work.path)
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertEqual((payload["tool_input"] as? [String: Any])?["command"] as? String, "rm -rf build")
        XCTAssertEqual(payload["tool_use_id"] as? String, "call_42")
        XCTAssertEqual(payload["permission_mode"] as? String, "acceptEdits")
        XCTAssertTrue(payload["transcript_path"] is NSNull)
        XCTAssertNotNil(payload["model"] as? String)
        XCTAssertNotNil(payload["turn_id"] as? String)

        let pluginRoot = try XCTUnwrap(model.installedPlugins.first?.root)
        XCTAssertEqual(try dataFile(model, "root.txt"), pluginRoot)
        XCTAssertEqual(try dataFile(model, "pwd.txt")?.trimmingCharacters(in: .newlines), PluginPath.real(work.path), "hooks run in the thread's working directory")
    }

    func testRewriteKeepsTheOtherArguments() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, groups: [group(#"printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo safe"}}}'"#)])
        let hooks = try XCTUnwrap(model.toolHooks)
        let spec = AgentToolSpec(name: "shell", description: "", parametersJSON: "{}", risk: .execute, source: "内置")
        let decision = await hooks.preToolUse(ToolCall(id: "c1", name: "shell", argumentsJSON: shell), spec, model.toolContext(for: id))
        XCTAssertEqual(decision, .rewrite(argumentsJSON: #"{"command":"echo safe","timeout_seconds":5}"#))
    }

    func testPermissionRequestAllowSkipsTheCard() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, event: "PermissionRequest", groups: [group(#"printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'"#, matcher: "Bash")])
        let hooks = try XCTUnwrap(model.toolHooks)
        let spec = AgentToolSpec(name: "shell", description: "", parametersJSON: "{}", risk: .execute, source: "内置")
        let decision = await hooks.permissionRequest(ToolCall(id: "c1", name: "shell", argumentsJSON: shell), spec, model.toolContext(for: id))
        XCTAssertEqual(decision, .allow)
    }

    func testPostToolUseReplacesOrAppends() async throws {
        let model = await makeModel()
        let id = thread(model)
        try install(model, event: "PostToolUse", groups: [
            group(#"grep -q secret && printf '%s' '{"decision":"block","reason":"output withheld: it contained a secret"}' || printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"output reviewed"}}'"#),
        ])
        let hooks = try XCTUnwrap(model.toolHooks)
        let spec = AgentToolSpec(name: "shell", description: "", parametersJSON: "{}", risk: .execute, source: "内置")
        let call = ToolCall(id: "c1", name: "shell", argumentsJSON: shell)
        let leaked = await hooks.postToolUse(call, spec, ToolResult(callID: "c1", name: "shell", outputText: "token: secret"), model.toolContext(for: id))
        XCTAssertEqual(leaked, .replace("output withheld: it contained a secret"))
        let clean = await hooks.postToolUse(call, spec, ToolResult(callID: "c1", name: "shell", outputText: "all good"), model.toolContext(for: id))
        XCTAssertEqual(clean, .append("output reviewed"))
    }
}
