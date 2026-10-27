import Foundation

/// What a PreToolUse hook says about one call (Codex `PreToolUse`).
public enum PreToolUseDecision: Sendable, Equatable {
    /// No opinion.
    case proceed
    /// Run with these arguments instead. They replace the model's before the
    /// risk check, so the approval card shows what will actually run.
    case rewrite(argumentsJSON: String)
    /// Refuse the call; the text is the error result the model sees.
    case block(String)
}

/// What a PermissionRequest hook says about a call that would show an
/// approval card (Codex `PermissionRequest`).
public enum PermissionHookDecision: Sendable, Equatable {
    /// Show the card as usual.
    case undecided
    /// Run without the card.
    case allow
    /// Refuse without the card; the text is the error result the model sees.
    case deny(String)
}

/// What a PostToolUse hook does with a result (Codex `PostToolUse`).
public enum PostToolUseDecision: Sendable, Equatable {
    case keep
    /// Add this text after the tool's output (`additionalContext`).
    case append(String)
    /// Show the model this text instead of the output (`decision: block`).
    case replace(String)
}

/// Plugin hooks around every routed tool call. Set through
/// `ChatAppModel.setToolHooks`.
public struct AgentToolHooks: Sendable {
    /// Runs before the risk check, the policy and any approval card.
    public var preToolUse: @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ context: AgentToolContext) async -> PreToolUseDecision
    /// Runs only when the policy says ask and 始终允许 is not set; never
    /// reached for a read-only refusal.
    public var permissionRequest: @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ context: AgentToolContext) async -> PermissionHookDecision
    /// Runs after the tool produced its result; not for blocked, refused,
    /// stopped or unknown calls.
    public var postToolUse: @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ result: ToolResult, _ context: AgentToolContext) async -> PostToolUseDecision

    public init(
        preToolUse: @escaping @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ context: AgentToolContext) async -> PreToolUseDecision,
        permissionRequest: @escaping @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ context: AgentToolContext) async -> PermissionHookDecision,
        postToolUse: @escaping @Sendable (_ call: ToolCall, _ spec: AgentToolSpec, _ result: ToolResult, _ context: AgentToolContext) async -> PostToolUseDecision
    ) {
        self.preToolUse = preToolUse
        self.permissionRequest = permissionRequest
        self.postToolUse = postToolUse
    }
}

/// The agent loop without UI or networking: run a model turn; when it ends
/// with tool calls, run them in order through the registry, the approval
/// policy and the user; hand the results back; let the host add the user's
/// follow-ups; repeat, at most `maxTurns` model turns per user message. The
/// host (the app model, or a test) streams the turns, shows approval cards
/// and records results.
public struct AgentLoop: Sendable {
    public static let maxModelTurns = 25

    public static let invalidArgumentsText = "参数不是合法 JSON"
    public static let deniedText = "用户拒绝了这次调用"
    public static let stoppedText = "用户停止了这次调用"
    public static let turnLimitText = "已达到每条消息 \(maxModelTurns) 轮模型调用的上限，这次调用没有执行"

    /// What one model turn produced.
    public enum TurnOutcome: Sendable {
        /// The turn finished. `calls` are its tool calls in order (none means
        /// it answered); `registry` is what that turn offered, and routes them.
        case finished(calls: [ToolCall], registry: AgentToolRegistry)
        /// The turn failed or was stopped; nothing runs.
        case stopped
    }

    public enum Ending: Equatable, Sendable {
        /// The model answered without calling anything.
        case answered
        /// A model turn failed or was stopped.
        case stopped
        /// Stopped while a tool ran or an approval card waited.
        case cancelled
        /// The last allowed turn still asked for tools; they did not run.
        case turnLimit
    }

    /// One finished call. Images ride beside the result: the host stores
    /// them and puts the references in `result.media`.
    public struct Execution: Sendable, Equatable {
        public var result: ToolResult
        public var images: [AgentToolImage]

        public init(result: ToolResult, images: [AgentToolImage] = []) {
            self.result = result
            self.images = images
        }
    }

    /// Read per call, so a mode switched while a card waits applies to the
    /// next call.
    public struct Environment: Sendable, Equatable {
        public var mode: PermissionMode
        public var context: AgentToolContext

        public init(mode: PermissionMode, context: AgentToolContext) {
            self.mode = mode
            self.context = context
        }
    }

    public struct Host: Sendable {
        /// Streams turn `turn` (1-based) and reports how it ended.
        public var modelTurn: @Sendable (_ turn: Int) async -> TurnOutcome
        public var environment: @Sendable () async -> Environment
        /// Whether the user chose 始终允许 for this tool this session.
        public var isAlwaysAllowed: @Sendable (_ toolName: String) async -> Bool
        /// Shows the card and suspends until the user answers. Must answer
        /// `.deny` when the task is cancelled.
        public var requestApproval: @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision
        /// The call passed every check and is about to run.
        public var willRun: @Sendable (ToolCall) async -> Void
        /// Every call of a turn ends here exactly once, in order — run,
        /// refused, failed or skipped — so no call is left without a result.
        public var didRun: @Sendable (ToolCall, Execution) async -> Void
        public var hooks: AgentToolHooks?
        /// Runs after every call of a turn has its result and before the next
        /// model turn: the one point where the host may append user messages
        /// (follow-ups sent while the reply ran) for the next request to
        /// carry. Returns whether it appended any; each delivery starts a new
        /// `maxTurns` budget, the cap being per user message.
        public var betweenTurns: @Sendable () async -> Bool

        public init(
            modelTurn: @escaping @Sendable (_ turn: Int) async -> TurnOutcome,
            environment: @escaping @Sendable () async -> Environment,
            isAlwaysAllowed: @escaping @Sendable (_ toolName: String) async -> Bool,
            requestApproval: @escaping @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision,
            willRun: @escaping @Sendable (ToolCall) async -> Void = { _ in },
            didRun: @escaping @Sendable (ToolCall, Execution) async -> Void,
            hooks: AgentToolHooks? = nil,
            betweenTurns: @escaping @Sendable () async -> Bool = { false }
        ) {
            self.modelTurn = modelTurn
            self.environment = environment
            self.isAlwaysAllowed = isAlwaysAllowed
            self.requestApproval = requestApproval
            self.willRun = willRun
            self.didRun = didRun
            self.hooks = hooks
            self.betweenTurns = betweenTurns
        }
    }

    public var maxTurns: Int

    public init(maxTurns: Int = AgentLoop.maxModelTurns) {
        self.maxTurns = max(1, maxTurns)
    }

    public func run(_ host: Host) async -> Ending {
        var turn = 1
        var lastTurn = maxTurns
        while true {
            guard case .finished(let calls, let registry) = await host.modelTurn(turn) else { return .stopped }
            // Nothing was offered: whatever the model claims to call is not ours to run.
            if calls.isEmpty || registry.isEmpty { return .answered }
            if turn >= lastTurn {
                for call in calls { await host.didRun(call, Self.failure(call, Self.turnLimitText)) }
                return .turnLimit
            }
            for (index, call) in calls.enumerated() {
                if Task.isCancelled {
                    for rest in calls[index...] { await host.didRun(rest, Self.failure(rest, Self.stoppedText)) }
                    return .cancelled
                }
                let execution = await execute(call, registry: registry, host: host)
                await host.didRun(call, execution)
            }
            if Task.isCancelled { return .cancelled }
            if await host.betweenTurns() { lastTurn = turn + maxTurns }
            turn += 1
        }
    }

    /// One call through every check: arguments, routing, hooks, risk, policy,
    /// approval, then the provider. Never throws: every failure is a result
    /// the model can read and react to.
    public func execute(_ call: ToolCall, registry: AgentToolRegistry, host: Host) async -> Execution {
        guard var arguments = Self.normalizedArguments(call.argumentsJSON) else {
            return Self.failure(call, Self.invalidArgumentsText)
        }
        guard let route = registry.route(call.name) else {
            return Self.failure(call, call.name.isEmpty ? "调用没有给出工具名" : "没有名为「\(call.name)」的工具")
        }
        let environment = await host.environment()
        let context = environment.context
        var normalized = call
        normalized.argumentsJSON = arguments

        if let hooks = host.hooks {
            switch await hooks.preToolUse(normalized, route.spec, context) {
            case .proceed:
                break
            case .rewrite(let replacement):
                guard let rewritten = Self.normalizedArguments(replacement) else {
                    return Self.failure(call, "插件钩子改写后的参数不是合法 JSON")
                }
                arguments = rewritten
                normalized.argumentsJSON = rewritten
            case .block(let reason):
                return Self.failure(call, reason.isEmpty ? "插件钩子阻止了这次调用" : reason)
            }
        }
        if Task.isCancelled { return Self.failure(call, Self.stoppedText) }

        let risk = await route.provider.risk(forCall: call.name, argumentsJSON: arguments, context: context)
        let always = await host.isAlwaysAllowed(call.name)
        switch ApprovalPolicy.decide(mode: environment.mode, risk: risk, alwaysAllowed: always) {
        case .deny:
            return Self.failure(call, Self.readOnlyText(risk))
        case .ask:
            let hookDecision = await host.hooks?.permissionRequest(normalized, route.spec, context) ?? .undecided
            if case .deny(let reason) = hookDecision {
                return Self.failure(call, reason.isEmpty ? Self.deniedText : reason)
            }
            // A hook may skip the card, except for desktop control, which always asks.
            if hookDecision != .allow || risk == .control {
                if Task.isCancelled { return Self.failure(call, Self.stoppedText) }
                let request = ToolApprovalRequest(
                    conversationID: context.conversationID,
                    callID: call.id,
                    toolName: call.name,
                    source: route.spec.source,
                    risk: risk,
                    argumentsJSON: arguments,
                    summary: route.provider.summary(forCall: call.name, argumentsJSON: arguments)
                )
                let decision = await host.requestApproval(request)
                if Task.isCancelled { return Self.failure(call, Self.stoppedText) }
                if decision == .deny { return Self.failure(call, Self.deniedText) }
            }
        case .allow:
            break
        }
        if Task.isCancelled { return Self.failure(call, Self.stoppedText) }

        await host.willRun(normalized)
        var execution: Execution
        do {
            let output = try await route.provider.call(call.name, argumentsJSON: arguments, context: context)
            execution = Execution(
                result: ToolResult(callID: call.id, name: call.name, outputText: output.text, isError: output.isError),
                images: output.images
            )
        } catch is CancellationError {
            return Self.failure(call, Self.stoppedText)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            execution = Self.failure(call, "工具执行失败：\(reason)")
        }
        if let hooks = host.hooks {
            switch await hooks.postToolUse(normalized, route.spec, execution.result, context) {
            case .keep:
                break
            case .append(let note):
                guard !note.isEmpty else { break }
                let text = execution.result.outputText
                execution.result.outputText = text.isEmpty ? note : text + "\n\n" + note
            case .replace(let feedback):
                execution = Self.failure(call, feedback)
            }
        }
        return execution
    }

    /// The arguments as sent, when they are a JSON object. Empty arguments
    /// (some models send none for a parameterless tool) count as `{}`.
    public static func normalizedArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              object is [String: Any] else { return nil }
        return trimmed
    }

    public static func failure(_ call: ToolCall, _ text: String) -> Execution {
        Execution(result: ToolResult(callID: call.id, name: call.name, outputText: text, isError: true))
    }

    static func readOnlyText(_ risk: ToolRisk) -> String {
        let action: String
        switch risk {
        case .read: action = "读取"
        case .write: action = "修改文件"
        case .execute: action = "运行命令或访问工作目录以外的位置"
        case .control: action = "控制桌面"
        }
        return "当前是只读模式，不能\(action)。可以继续读取工作目录里的文件，或请用户切换权限模式。"
    }
}
