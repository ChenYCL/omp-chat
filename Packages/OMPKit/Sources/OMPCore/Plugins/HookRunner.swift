import Foundation

/// A hook ready to run: its definition and where its plugin lives.
public struct PluginHook: Equatable, Sendable {
    public var definition: HookDefinition
    /// `PLUGIN_ROOT`: the installed plugin folder.
    public var pluginRoot: String
    /// `PLUGIN_DATA`: the plugin's writable data folder.
    public var pluginData: String

    public init(definition: HookDefinition, pluginRoot: String, pluginData: String) {
        self.definition = definition
        self.pluginRoot = pluginRoot
        self.pluginData = pluginData
    }
}

/// How Codex names the tool in hook input and matchers.
public enum HookToolKind: Sendable, Equatable {
    /// `Bash`; `tool_input.command` is the command line.
    case bash
    /// `apply_patch`; matchers may also say `Edit` or `Write`.
    case applyPatch
    /// `mcp__<server>__<tool>`; `tool_input` is the call's arguments.
    case mcp
}

/// One tool call as hooks see it: the stdin payload's fields.
public struct HookToolCall: Sendable, Equatable {
    public var kind: HookToolKind
    /// `tool_name`: `Bash`, `apply_patch` or `mcp__server__tool`.
    public var toolName: String
    /// `tool_input`, as JSON text.
    public var toolInputJSON: String
    /// `tool_use_id`: the model's call id.
    public var toolUseID: String
    /// `tool_response` for PostToolUse, as JSON text.
    public var toolResponseJSON: String?

    public init(kind: HookToolKind, toolName: String, toolInputJSON: String, toolUseID: String, toolResponseJSON: String? = nil) {
        self.kind = kind
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.toolUseID = toolUseID
        self.toolResponseJSON = toolResponseJSON
    }

    /// Names the matcher is tried against.
    var matcherNames: [String] {
        kind == .applyPatch ? [toolName, "Edit", "Write"] : [toolName]
    }
}

/// The session fields every hook receives.
public struct HookSession: Sendable, Equatable {
    public var sessionID: String
    public var turnID: String
    /// Where hook commands run, and the payload's `cwd`.
    public var cwd: String
    public var model: String
    /// `default`, `acceptEdits`, `plan`, `dontAsk` or `bypassPermissions`.
    public var permissionMode: String
    /// Nil is sent as JSON null: this app keeps no transcript file.
    public var transcriptPath: String?

    public init(sessionID: String, turnID: String, cwd: String, model: String, permissionMode: String, transcriptPath: String? = nil) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
    }

    /// Codex's name for each permission mode.
    public static func codexPermissionMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .readOnly: "plan"
        case .ask: "default"
        case .auto: "acceptEdits"
        case .full: "bypassPermissions"
        }
    }
}

public enum HookRunStatus: String, Sendable, Equatable {
    case completed
    case blocked
    case failed
    case stopped
}

/// One finished hook run, for the plugins pane's log.
public struct HookRunRecord: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var at: Date
    public var hookID: String
    public var pluginID: String
    public var event: HookEvent
    public var toolName: String
    public var command: String
    public var status: HookRunStatus
    /// Feedback, error or `systemMessage`.
    public var message: String?
}

/// Everything the matching hooks decided about one event.
public struct HookReport: Sendable, Equatable {
    public enum Permission: Sendable, Equatable {
        case allow
        case deny(String)
    }

    public var records: [HookRunRecord] = []
    /// PreToolUse: the call must not run; the model sees this text.
    public var blockReason: String?
    /// PreToolUse: `updatedInput` of the last hook to finish, as JSON text.
    public var updatedInputJSON: String?
    /// Model-visible `additionalContext`, in configuration order.
    public var additionalContext: [String] = []
    /// PermissionRequest: any deny wins, else an allow, else nil (ask).
    public var permission: Permission?
    /// PostToolUse: replaces the tool result the model sees.
    public var feedback: String?
    /// `systemMessage` warnings for the user.
    public var systemMessages: [String] = []
}

/// What the plugin hooks around one tool call decided
/// (`ChatAppModel.runToolHooks`).
public enum HookOutcome: Equatable, Sendable {
    /// Go ahead. `context` is model-visible text the hooks added
    /// (`additionalContext`); `updatedArgumentsJSON` replaces the call's
    /// arguments (PreToolUse `updatedInput`).
    case allow(context: String?, updatedArgumentsJSON: String?)
    /// PermissionRequest `allow`: run without the approval card.
    case approve
    /// PreToolUse / PermissionRequest: do not run. PostToolUse: show the
    /// model this text instead of the result.
    case block(String)
}

/// Runs plugin hooks with Codex's semantics: matching handlers start
/// together, each gets one JSON object on stdin, and its exit code and stdout
/// decide (exit 0 + JSON, or exit 2 + stderr). A hook that fails — non-zero
/// exit, timeout, unparsable JSON, an unsupported field — is recorded and
/// the call goes on.
public struct HookRunner: Sendable {
    private let runner: PluginCommandRunner

    public init(runner: @escaping PluginCommandRunner) {
        self.runner = runner
    }

    /// Hooks among `hooks` that `event` and `call` select.
    public static func matching(_ hooks: [PluginHook], event: HookEvent, call: HookToolCall) -> [PluginHook] {
        hooks.filter { hook in
            let definition = hook.definition
            guard definition.event == event, definition.runs else { return false }
            guard event.usesMatcher else { return true }
            guard let matcher = try? HookMatcher(definition.matcher) else { return false }
            return matcher.matches(call.matcherNames)
        }
    }

    public func run(_ event: HookEvent, call: HookToolCall, session: HookSession, hooks: [PluginHook]) async -> HookReport {
        let selected = Self.matching(hooks, event: event, call: call)
        guard !selected.isEmpty else { return HookReport() }
        let payload = Self.payload(event: event, call: call, session: session)

        // Codex launches matching hooks concurrently and folds the results
        // in configuration order; `updatedInput` goes to the last to finish.
        var outcomes = [Outcome?](repeating: nil, count: selected.count)
        var completionOrder: [Int] = []
        await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, hook) in selected.enumerated() {
                group.addTask {
                    let result = await runner(PluginCommand(
                        command: hook.definition.handler.command ?? "",
                        cwd: session.cwd,
                        stdin: payload,
                        timeout: Double(max(1, hook.definition.handler.timeout)),
                        environment: [
                            "PLUGIN_ROOT": hook.pluginRoot,
                            "PLUGIN_DATA": hook.pluginData,
                            "CLAUDE_PLUGIN_ROOT": hook.pluginRoot,
                            "CLAUDE_PLUGIN_DATA": hook.pluginData,
                        ],
                        loginShell: true
                    ))
                    return (index, Self.interpret(result, event: event, call: call, timeout: max(1, hook.definition.handler.timeout)))
                }
            }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                completionOrder.append(index)
            }
        }

        var report = HookReport()
        let now = Date()
        for (index, hook) in selected.enumerated() {
            guard let outcome = outcomes[index] else { continue }
            report.records.append(HookRunRecord(
                at: now, hookID: hook.definition.id, pluginID: hook.definition.pluginID,
                event: event, toolName: call.toolName, command: hook.definition.handler.command ?? "",
                status: outcome.status, message: outcome.message ?? outcome.systemMessages.first
            ))
            report.additionalContext.append(contentsOf: outcome.additionalContext)
            report.systemMessages.append(contentsOf: outcome.systemMessages)
            if let reason = outcome.blockReason, report.blockReason == nil {
                report.blockReason = reason
            }
            switch outcome.permission {
            case .deny(let message)?:
                if case .deny? = report.permission {} else { report.permission = .deny(message) }
            case .allow?:
                if report.permission == nil { report.permission = .allow }
            case nil:
                break
            }
        }
        if report.blockReason == nil {
            report.updatedInputJSON = completionOrder.reversed().lazy.compactMap { outcomes[$0]?.updatedInputJSON }.first
        }
        let feedback = outcomes.compactMap { $0?.feedback }
        report.feedback = feedback.isEmpty ? nil : feedback.joined(separator: "\n\n")
        return report
    }

    // MARK: Payload

    static func payload(event: HookEvent, call: HookToolCall, session: HookSession) -> Data {
        var object: [String: Any] = [
            "session_id": session.sessionID,
            "turn_id": session.turnID,
            "transcript_path": session.transcriptPath.map { $0 as Any } ?? NSNull(),
            "cwd": session.cwd,
            "hook_event_name": event.rawValue,
            "model": session.model,
            "permission_mode": session.permissionMode,
            "tool_name": call.toolName,
            "tool_input": jsonValue(call.toolInputJSON) ?? [String: Any](),
        ]
        if event != .permissionRequest {
            object["tool_use_id"] = call.toolUseID
        }
        if event == .postToolUse {
            object["tool_response"] = call.toolResponseJSON.flatMap(jsonValue) ?? NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func jsonValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Interpretation

    struct Outcome {
        var status: HookRunStatus = .completed
        var message: String?
        var blockReason: String?
        var updatedInputJSON: String?
        var additionalContext: [String] = []
        var permission: HookReport.Permission?
        var feedback: String?
        var systemMessages: [String] = []

        static func failed(_ message: String) -> Outcome {
            Outcome(status: .failed, message: message)
        }
    }

    static func interpret(_ result: PluginCommandResult, event: HookEvent, call: HookToolCall, timeout: Int) -> Outcome {
        if let launchError = result.launchError { return .failed("钩子无法启动：\(launchError)") }
        if result.timedOut { return .failed("钩子超时（\(timeout) 秒）") }
        switch result.exitCode {
        case 0:
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if stdout.isEmpty { return Outcome() }
            guard let data = stdout.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Plain text is ignored for tool events; text that looks
                // like JSON but is not is a failed hook.
                return stdout.hasPrefix("{") || stdout.hasPrefix("[") ? .failed("钩子输出的 JSON 无法解析") : Outcome()
            }
            switch event {
            case .preToolUse: return preToolUse(object, call: call)
            case .permissionRequest: return permissionRequest(object)
            case .postToolUse: return postToolUse(object)
            default: return Outcome()
            }
        case 2:
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                return .failed("钩子以退出码 2 结束，但没有在 stderr 写原因")
            }
            switch event {
            case .preToolUse:
                return Outcome(status: .blocked, message: reason, blockReason: reason)
            case .permissionRequest:
                return Outcome(status: .blocked, message: reason, permission: .deny(reason))
            case .postToolUse:
                return Outcome(status: .blocked, message: reason, feedback: reason)
            default:
                return Outcome(status: .blocked, message: reason)
            }
        default:
            return .failed("钩子退出码 \(result.exitCode)")
        }
    }

    /// The universal output fields, validated.
    private struct Universal {
        var continueProcessing = true
        var stopReason: String?
        var suppressOutput = false
        var systemMessage: String?
    }

    private static let universalKeys: Set<String> = ["continue", "stopReason", "suppressOutput", "systemMessage"]

    /// Codex's output types reject unknown fields and wrong types; any such
    /// output makes the hook run fail.
    private static func universal(_ object: [String: Any], allowed: Set<String>) -> Universal? {
        guard Set(object.keys).isSubset(of: universalKeys.union(allowed)) else { return nil }
        var universal = Universal()
        if let value = object["continue"] {
            guard let flag = value as? Bool else { return nil }
            universal.continueProcessing = flag
        }
        if let value = object["stopReason"], !(value is NSNull) {
            guard let text = value as? String else { return nil }
            universal.stopReason = text
        }
        if let value = object["suppressOutput"] {
            guard let flag = value as? Bool else { return nil }
            universal.suppressOutput = flag
        }
        if let value = object["systemMessage"], !(value is NSNull) {
            guard let text = value as? String else { return nil }
            universal.systemMessage = text
        }
        return universal
    }

    /// `hookSpecificOutput`, checked for its allowed keys and a known
    /// `hookEventName`. `.some(nil)` means absent.
    private static func specific(_ object: [String: Any], allowed: Set<String>) -> [String: Any]?? {
        guard let value = object["hookSpecificOutput"], !(value is NSNull) else { return .some(nil) }
        guard let specific = value as? [String: Any],
              Set(specific.keys).isSubset(of: allowed.union(["hookEventName"])),
              let name = specific["hookEventName"] as? String, HookEvent(rawValue: name) != nil else { return nil }
        return .some(specific)
    }

    private static func optionalString(_ object: [String: Any]?, _ key: String) -> String?? {
        guard let value = object?[key], !(value is NSNull) else { return .some(nil) }
        guard let text = value as? String else { return nil }
        return .some(text)
    }

    private static func trimmed(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static let invalidOutput = "钩子输出的 JSON 字段无法识别"

    private static func preToolUse(_ object: [String: Any], call: HookToolCall) -> Outcome {
        guard let universal = universal(object, allowed: ["decision", "reason", "hookSpecificOutput"]),
              case .some(let specific) = specific(object, allowed: ["permissionDecision", "permissionDecisionReason", "updatedInput", "additionalContext"]),
              case .some(let reason) = optionalString(object, "reason"),
              case .some(let decision) = optionalString(object, "decision"),
              decision == nil || decision == "approve" || decision == "block",
              case .some(let permissionDecision) = optionalString(specific, "permissionDecision"),
              permissionDecision == nil || ["allow", "deny", "ask"].contains(permissionDecision!),
              case .some(let permissionReason) = optionalString(specific, "permissionDecisionReason"),
              case .some(let context) = optionalString(specific, "additionalContext") else {
            return .failed(invalidOutput)
        }
        let updatedInput = specific?["updatedInput"].flatMap { $0 is NSNull ? nil : $0 }

        var outcome = Outcome()
        outcome.systemMessages = universal.systemMessage.map { [$0] } ?? []
        if let context = trimmed(context) { outcome.additionalContext = [context] }

        // Fields Codex parses but does not support make the run fail; the
        // call itself goes on.
        if !universal.continueProcessing { return failing(outcome, "PreToolUse 不支持 continue:false") }
        if universal.stopReason != nil { return failing(outcome, "PreToolUse 不支持 stopReason") }
        if universal.suppressOutput { return failing(outcome, "PreToolUse 不支持 suppressOutput") }

        let usesSpecific = permissionDecision != nil || permissionReason != nil || updatedInput != nil
        if usesSpecific {
            if updatedInput != nil, permissionDecision != "allow" {
                return failing(outcome, "updatedInput 只能和 permissionDecision:allow 一起返回")
            }
            switch permissionDecision {
            case "allow":
                guard let updatedInput else { return failing(outcome, "PreToolUse 不支持只返回 permissionDecision:allow") }
                if call.kind != .mcp {
                    guard let replacement = updatedInput as? [String: Any], replacement["command"] is String else {
                        return failing(outcome, "\(call.toolName) 的 updatedInput 必须带字符串 command")
                    }
                }
                guard JSONSerialization.isValidJSONObject(updatedInput),
                      let data = try? JSONSerialization.data(withJSONObject: updatedInput, options: [.sortedKeys]) else {
                    return failing(outcome, "MCP 工具的 updatedInput 必须是参数对象")
                }
                outcome.updatedInputJSON = String(decoding: data, as: UTF8.self)
                return outcome
            case "ask":
                return failing(outcome, "PreToolUse 不支持 permissionDecision:ask")
            case "deny":
                guard let reason = trimmed(permissionReason) else {
                    return failing(outcome, "permissionDecision:deny 需要非空的 permissionDecisionReason")
                }
                outcome.status = .blocked
                outcome.message = reason
                outcome.blockReason = reason
                return outcome
            default:
                return failing(outcome, "permissionDecisionReason 缺少 permissionDecision")
            }
        }
        switch decision {
        case "approve":
            return failing(outcome, "PreToolUse 不支持 decision:approve")
        case "block":
            guard let reason = trimmed(reason) else { return failing(outcome, "decision:block 需要非空的 reason") }
            outcome.status = .blocked
            outcome.message = reason
            outcome.blockReason = reason
            return outcome
        default:
            if reason != nil { return failing(outcome, "reason 缺少 decision") }
            return outcome
        }
    }

    private static func permissionRequest(_ object: [String: Any]) -> Outcome {
        guard let universal = universal(object, allowed: ["hookSpecificOutput"]),
              case .some(let specific) = specific(object, allowed: ["decision"]) else {
            return .failed(invalidOutput)
        }
        var outcome = Outcome()
        outcome.systemMessages = universal.systemMessage.map { [$0] } ?? []
        if !universal.continueProcessing { return failing(outcome, "PermissionRequest 不支持 continue:false") }
        if universal.stopReason != nil { return failing(outcome, "PermissionRequest 不支持 stopReason") }
        if universal.suppressOutput { return failing(outcome, "PermissionRequest 不支持 suppressOutput") }
        guard let rawDecision = specific?["decision"], !(rawDecision is NSNull) else { return outcome }
        guard let decision = rawDecision as? [String: Any],
              Set(decision.keys).isSubset(of: ["behavior", "updatedInput", "updatedPermissions", "message", "interrupt"]),
              let behavior = decision["behavior"] as? String, behavior == "allow" || behavior == "deny",
              case .some(let message) = optionalString(decision, "message") else {
            return .failed(invalidOutput)
        }
        // Reserved fields fail closed: the decision is not applied.
        if let value = decision["updatedInput"], !(value is NSNull) { return failing(outcome, "PermissionRequest 不支持 updatedInput") }
        if let value = decision["updatedPermissions"], !(value is NSNull) { return failing(outcome, "PermissionRequest 不支持 updatedPermissions") }
        if let value = decision["interrupt"] {
            guard let flag = value as? Bool else { return .failed(invalidOutput) }
            if flag { return failing(outcome, "PermissionRequest 不支持 interrupt:true") }
        }
        if behavior == "allow" {
            outcome.permission = .allow
        } else {
            let text = trimmed(message) ?? "插件钩子拒绝了这次调用"
            outcome.status = .blocked
            outcome.message = text
            outcome.permission = .deny(text)
        }
        return outcome
    }

    private static func postToolUse(_ object: [String: Any]) -> Outcome {
        guard let universal = universal(object, allowed: ["decision", "reason", "hookSpecificOutput"]),
              case .some(let specific) = specific(object, allowed: ["additionalContext", "updatedMCPToolOutput"]),
              case .some(let reason) = optionalString(object, "reason"),
              case .some(let decision) = optionalString(object, "decision"),
              decision == nil || decision == "block",
              case .some(let context) = optionalString(specific, "additionalContext") else {
            return .failed(invalidOutput)
        }
        var outcome = Outcome()
        outcome.systemMessages = universal.systemMessage.map { [$0] } ?? []
        let unsupported: String?
        if universal.suppressOutput {
            unsupported = "PostToolUse 不支持 suppressOutput"
        } else if let value = specific?["updatedMCPToolOutput"], !(value is NSNull) {
            unsupported = "PostToolUse 不支持 updatedMCPToolOutput"
        } else {
            unsupported = nil
        }
        let blocks = decision == "block"
        let invalidBlock: String?
        if blocks, trimmed(reason) == nil {
            invalidBlock = "decision:block 需要非空的 reason"
        } else if !blocks, universal.continueProcessing, reason != nil {
            invalidBlock = "reason 缺少 decision"
        } else {
            invalidBlock = nil
        }
        if unsupported == nil, invalidBlock == nil, let context = trimmed(context) {
            outcome.additionalContext = [context]
        }
        if !universal.continueProcessing {
            let stop = universal.stopReason ?? "插件钩子停止了后续处理"
            outcome.status = .stopped
            outcome.message = stop
            outcome.feedback = trimmed(reason) ?? stop
            return outcome
        }
        if let unsupported { return failing(outcome, unsupported) }
        if let invalidBlock { return failing(outcome, invalidBlock) }
        if blocks, let reason = trimmed(reason) {
            outcome.status = .blocked
            outcome.message = reason
            outcome.feedback = reason
        }
        return outcome
    }

    private static func failing(_ outcome: Outcome, _ message: String) -> Outcome {
        // A failed run applies nothing, not even its additionalContext; only
        // the systemMessage warning survives.
        Outcome(status: .failed, message: message, systemMessages: outcome.systemMessages)
    }
}
