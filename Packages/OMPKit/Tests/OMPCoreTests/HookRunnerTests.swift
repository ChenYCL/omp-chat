import XCTest
@testable import OMPCore

/// Codex hook semantics with scripted command results: which outputs block,
/// which rewrite, which merely fail while the call goes on. A wrong reading
/// either runs a call a policy hook refused or blocks one it allowed.
final class HookRunnerTests: XCTestCase {
    /// Answers each command with the result scripted for it.
    private final class ScriptedRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: PluginCommandResult]
        private var delays: [String: Double]
        private(set) var commands: [PluginCommand] = []

        init(_ results: [String: PluginCommandResult], delays: [String: Double] = [:]) {
            self.results = results
            self.delays = delays
        }

        var runner: PluginCommandRunner {
            { [self] command in
                lock.withLock { commands.append(command) }
                if let delay = delays[command.command] {
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                }
                return lock.withLock { results[command.command] } ?? PluginCommandResult(exitCode: 0)
            }
        }
    }

    private func hook(_ command: String, event: HookEvent = .preToolUse, matcher: String? = nil, timeout: Int = 600) -> PluginHook {
        PluginHook(
            definition: HookDefinition(
                id: "p:hooks/hooks.json:\(event.rawValue):0:\(command)", pluginID: "p", source: "hooks/hooks.json",
                event: event, matcher: matcher, handler: HookHandler(command: command, timeout: timeout)
            ),
            pluginRoot: "/plugins/p", pluginData: "/data/p"
        )
    }

    private let bash = HookToolCall(kind: .bash, toolName: "Bash", toolInputJSON: #"{"command":"rm -rf build"}"#, toolUseID: "call_1")
    private let session = HookSession(sessionID: "s", turnID: "t", cwd: "/work", model: "m", permissionMode: "default")

    private func run(_ event: HookEvent, _ results: [String: PluginCommandResult], hooks: [PluginHook], call: HookToolCall? = nil) async -> HookReport {
        await HookRunner(runner: ScriptedRunner(results).runner).run(event, call: call ?? bash, session: session, hooks: hooks)
    }

    private func json(_ text: String) -> PluginCommandResult {
        PluginCommandResult(exitCode: 0, stdout: text)
    }

    // MARK: PreToolUse

    func testDenyDecisionLegacyBlockAndExitTwoAllBlock() async {
        let deny = await run(.preToolUse, ["h": json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":" Destructive command blocked. "}}"#)], hooks: [hook("h")])
        XCTAssertEqual(deny.blockReason, "Destructive command blocked.")
        XCTAssertEqual(deny.records.map(\.status), [.blocked])

        let legacy = await run(.preToolUse, ["h": json(#"{"decision":"block","reason":"no"}"#)], hooks: [hook("h")])
        XCTAssertEqual(legacy.blockReason, "no")

        let exit2 = await run(.preToolUse, ["h": PluginCommandResult(exitCode: 2, stderr: "policy says no\n")], hooks: [hook("h")])
        XCTAssertEqual(exit2.blockReason, "policy says no")
    }

    func testFailuresLetTheCallGoOn() async {
        let cases: [(String, PluginCommandResult)] = [
            ("exit 1", PluginCommandResult(exitCode: 1, stderr: "boom")),
            ("exit 2 without a reason", PluginCommandResult(exitCode: 2)),
            ("timeout", PluginCommandResult(exitCode: 137, timedOut: true)),
            ("launch failure", PluginCommandResult(exitCode: -1, launchError: "no shell")),
            ("broken JSON", json(#"{"decision":"#)),
            ("unknown field", json(#"{"decision":"block","reason":"x","extra":1}"#)),
            ("wrong type", json(#"{"systemMessage":42}"#)),
            ("missing hookEventName", json(#"{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"x"}}"#)),
            ("allow without updatedInput", json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#)),
            ("ask", json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"?"}}"#)),
            ("approve", json(#"{"decision":"approve"}"#)),
            ("continue false", json(#"{"continue":false,"decision":"block","reason":"x"}"#)),
            ("deny without reason", json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}"#)),
            ("block without reason", json(#"{"decision":"block"}"#)),
        ]
        for (label, result) in cases {
            let report = await run(.preToolUse, ["h": result], hooks: [hook("h")])
            XCTAssertNil(report.blockReason, label)
            XCTAssertNil(report.updatedInputJSON, label)
            XCTAssertEqual(report.records.map(\.status), [.failed], label)
            XCTAssertNotNil(report.records.first?.message, label)
        }
    }

    func testPlainTextAndEmptyOutputAreSuccess() async {
        for result in [PluginCommandResult(exitCode: 0), json("checked, all fine\n")] {
            let report = await run(.preToolUse, ["h": result], hooks: [hook("h")])
            XCTAssertNil(report.blockReason)
            XCTAssertEqual(report.records.map(\.status), [.completed])
        }
    }

    func testAnyBlockWinsAndTheFirstReasonIsShown() async {
        let report = await run(.preToolUse, [
            "a": PluginCommandResult(exitCode: 0),
            "b": PluginCommandResult(exitCode: 2, stderr: "second says no"),
            "c": json(#"{"decision":"block","reason":"third says no"}"#),
        ], hooks: [hook("a"), hook("b"), hook("c")])
        XCTAssertEqual(report.blockReason, "second says no")
        XCTAssertEqual(report.records.map(\.status), [.completed, .blocked, .blocked])
    }

    func testRewriteUsesTheLastHookToFinishAndNeedsACommand() async {
        let early = json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo configured first"}}}"#)
        let late = json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo finished last"}}}"#)
        let scripted = ScriptedRunner(["first": early, "second": late], delays: ["first": 0.3])
        let report = await HookRunner(runner: scripted.runner).run(.preToolUse, call: bash, session: session, hooks: [hook("first"), hook("second")])
        XCTAssertEqual(report.updatedInputJSON, #"{"command":"echo configured first"}"#, "the hook that finished last wins, not the one configured last")

        let noCommand = await run(.preToolUse, ["h": json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"cmd":"x"}}}"#)], hooks: [hook("h")])
        XCTAssertNil(noCommand.updatedInputJSON)
        XCTAssertEqual(noCommand.records.map(\.status), [.failed])

        let mcp = HookToolCall(kind: .mcp, toolName: "mcp__fs__read", toolInputJSON: #"{"path":"a"}"#, toolUseID: "c")
        let mcpRewrite = await run(.preToolUse, ["h": json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"path":"b"}}}"#)], hooks: [hook("h")], call: mcp)
        XCTAssertEqual(mcpRewrite.updatedInputJSON, #"{"path":"b"}"#, "MCP arguments need no command field")

        let blocked = await run(.preToolUse, ["a": late, "b": PluginCommandResult(exitCode: 2, stderr: "no")], hooks: [hook("a"), hook("b")])
        XCTAssertNil(blocked.updatedInputJSON, "a block discards rewrites")
    }

    func testAdditionalContextAndSystemMessage() async {
        let report = await run(.preToolUse, ["h": json(#"{"systemMessage":"heads up","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"touches generated files"}}"#)], hooks: [hook("h")])
        XCTAssertNil(report.blockReason)
        XCTAssertEqual(report.additionalContext, ["touches generated files"])
        XCTAssertEqual(report.systemMessages, ["heads up"])

        let invalid = await run(.preToolUse, ["h": json(#"{"suppressOutput":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"lost"}}"#)], hooks: [hook("h")])
        XCTAssertTrue(invalid.additionalContext.isEmpty, "a failed run adds no context")
    }

    // MARK: PermissionRequest

    func testPermissionRequestDenyWinsOverAllow() async {
        let allow = json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        let deny = json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"repo policy"}}}"#)
        let both = await run(.permissionRequest, ["a": allow, "b": deny], hooks: [hook("a", event: .permissionRequest), hook("b", event: .permissionRequest)])
        XCTAssertEqual(both.permission, .deny("repo policy"))

        let onlyAllow = await run(.permissionRequest, ["a": allow], hooks: [hook("a", event: .permissionRequest)])
        XCTAssertEqual(onlyAllow.permission, .allow)

        let silent = await run(.permissionRequest, ["a": PluginCommandResult(exitCode: 0)], hooks: [hook("a", event: .permissionRequest)])
        XCTAssertNil(silent.permission, "no decision: the approval card shows")

        let reserved = await run(.permissionRequest, ["a": json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{}}}}"#)], hooks: [hook("a", event: .permissionRequest)])
        XCTAssertNil(reserved.permission, "reserved fields fail closed: no allow")

        let exit2 = await run(.permissionRequest, ["a": PluginCommandResult(exitCode: 2, stderr: "denied by script")], hooks: [hook("a", event: .permissionRequest)])
        XCTAssertEqual(exit2.permission, .deny("denied by script"))
    }

    // MARK: PostToolUse

    func testPostToolUseFeedbackReplacesTheResult() async {
        let post = HookToolCall(kind: .bash, toolName: "Bash", toolInputJSON: #"{"command":"ls"}"#, toolUseID: "c", toolResponseJSON: #""a\nb""#)
        let block = await run(.postToolUse, ["h": json(#"{"decision":"block","reason":"output needs review","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"updated generated files"}}"#)], hooks: [hook("h", event: .postToolUse)], call: post)
        XCTAssertEqual(block.feedback, "output needs review")
        XCTAssertEqual(block.additionalContext, ["updated generated files"])

        let stop = await run(.postToolUse, ["h": json(#"{"continue":false,"stopReason":"halt here"}"#)], hooks: [hook("h", event: .postToolUse)], call: post)
        XCTAssertEqual(stop.feedback, "halt here")
        XCTAssertEqual(stop.records.map(\.status), [.stopped])

        let exit2 = await run(.postToolUse, ["h": PluginCommandResult(exitCode: 2, stderr: "bad output")], hooks: [hook("h", event: .postToolUse)], call: post)
        XCTAssertEqual(exit2.feedback, "bad output")

        let unsupported = await run(.postToolUse, ["h": json(#"{"decision":"block","reason":"x","hookSpecificOutput":{"hookEventName":"PostToolUse","updatedMCPToolOutput":{}}}"#)], hooks: [hook("h", event: .postToolUse)], call: post)
        XCTAssertNil(unsupported.feedback)
        XCTAssertEqual(unsupported.records.map(\.status), [.failed])
    }

    // MARK: Matching and payload

    func testMatcherSemantics() throws {
        func matches(_ pattern: String?, _ names: [String]) throws -> Bool { try HookMatcher(pattern).matches(names) }
        XCTAssertTrue(try matches(nil, ["anything"]))
        XCTAssertTrue(try matches("*", ["anything"]))
        XCTAssertTrue(try matches("", ["anything"]))
        XCTAssertTrue(try matches("Bash", ["Bash"]))
        XCTAssertFalse(try matches("Bash", ["BashOutput"]), "a plain name is exact, not a prefix")
        XCTAssertTrue(try matches("Edit|Write", ["apply_patch", "Edit", "Write"]))
        XCTAssertTrue(try matches("mcp__fs__.*", ["mcp__fs__read"]))
        XCTAssertTrue(try matches("fs__read", ["mcp__fs__read"]) == false, "letters and underscores only: exact")
        XCTAssertTrue(try matches("^apply_patch$", ["apply_patch"]))
        XCTAssertTrue(try matches("read$", ["mcp__fs__read"]), "a regex searches anywhere")
        XCTAssertThrowsError(try HookMatcher("(unclosed"))
    }

    func testOnlyMatchingHooksOfTheEventRun() async {
        let scripted = ScriptedRunner([:])
        let hooks = [
            hook("bash-only", matcher: "Bash"),
            hook("edits", matcher: "Edit|Write"),
            hook("post", event: .postToolUse),
            hook("stop", event: .stop),
        ]
        let patch = HookToolCall(kind: .applyPatch, toolName: "apply_patch", toolInputJSON: "{}", toolUseID: "c")
        _ = await HookRunner(runner: scripted.runner).run(.preToolUse, call: patch, session: session, hooks: hooks)
        XCTAssertEqual(scripted.commands.map(\.command), ["edits"])
    }

    func testPayloadEnvironmentAndShell() async throws {
        let scripted = ScriptedRunner([:])
        _ = await HookRunner(runner: scripted.runner).run(.preToolUse, call: bash, session: session, hooks: [hook("h", timeout: 30)])
        let command = try XCTUnwrap(scripted.commands.first)
        XCTAssertEqual(command.cwd, "/work")
        XCTAssertEqual(command.timeout, 30)
        XCTAssertTrue(command.loginShell)
        XCTAssertEqual(command.environment["PLUGIN_ROOT"], "/plugins/p")
        XCTAssertEqual(command.environment["CLAUDE_PLUGIN_DATA"], "/data/p")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(command.stdin)) as? [String: Any])
        XCTAssertEqual(payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertEqual((payload["tool_input"] as? [String: Any])?["command"] as? String, "rm -rf build")
        XCTAssertEqual(payload["tool_use_id"] as? String, "call_1")
        XCTAssertEqual(payload["permission_mode"] as? String, "default")
        XCTAssertTrue(payload["transcript_path"] is NSNull)
        XCTAssertNil(payload["tool_response"])
    }

    // MARK: Hooks file

    func testHooksFileFlattensGroupsAndFlagsWhatWillNotRun() throws {
        let data = Data("""
        {"hooks": {
          "PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "check.sh", "timeout": 30, "statusMessage": "Checking"},
            {"type": "prompt", "prompt": "think"},
            {"type": "command", "command": "later.sh", "async": true}
          ]}],
          "PostToolUse": [{"matcher": "(bad", "hooks": [{"type": "command", "command": "x"}]}],
          "Stop": [{"matcher": "ignored", "hooks": [{"type": "command", "command": "stop.sh"}]}],
          "Notification": [{"hooks": []}]
        }}
        """.utf8)
        let parsed = try HooksFile.parse(data, pluginID: "p", source: "hooks/hooks.json")
        XCTAssertEqual(parsed.hooks.map(\.handler.command), ["check.sh", nil, "later.sh", "x", "stop.sh"])
        XCTAssertEqual(parsed.hooks.map(\.runs), [true, false, false, false, false])
        XCTAssertEqual(parsed.hooks[0].handler.timeout, 30)
        XCTAssertEqual(parsed.hooks[0].id, "p:hooks/hooks.json:PreToolUse:0:0")
        XCTAssertNotNil(parsed.hooks[3].matcherProblem)
        XCTAssertNil(parsed.hooks[4].matcher, "Stop ignores its matcher")
        XCTAssertEqual(parsed.hooks[4].handler.timeout, 600, "Codex default")
        XCTAssertEqual(parsed.warnings.count, 1, "unknown event")

        XCTAssertThrowsError(try HooksFile.parse(Data(#"{"hooks": {"PreToolUse": [{"hooks": [{"command": "no type"}]}]}}"#.utf8), pluginID: "p", source: "s"))
        XCTAssertThrowsError(try HooksFile.parse(Data(#"{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "x", "timeout": "30"}]}]}}"#.utf8), pluginID: "p", source: "s"))
    }
}
