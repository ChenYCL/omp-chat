import Foundation

/// Codex lifecycle events (developers.openai.com/codex/hooks).
public enum HookEvent: String, CaseIterable, Codable, Sendable {
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"

    /// Events this app fires: the three around a tool call. The others are
    /// parsed and listed, but nothing here triggers them.
    public var isTriggered: Bool {
        switch self {
        case .preToolUse, .permissionRequest, .postToolUse: true
        default: false
        }
    }

    /// `UserPromptSubmit` and `Stop` ignore any configured matcher.
    public var usesMatcher: Bool {
        self != .userPromptSubmit && self != .stop
    }
}

/// One handler from a hooks file.
public struct HookHandler: Equatable, Sendable {
    /// Codex runs 600 seconds when `timeout` is left out.
    public static let defaultTimeout = 600

    /// `command`, `prompt` or `agent`; only `command` runs.
    public var type: String
    public var command: String?
    /// Seconds.
    public var timeout: Int
    public var statusMessage: String?
    /// Parsed; Codex skips async handlers, and so does this app.
    public var isAsync: Bool

    public init(type: String = "command", command: String?, timeout: Int = HookHandler.defaultTimeout, statusMessage: String? = nil, isAsync: Bool = false) {
        self.type = type
        self.command = command
        self.timeout = timeout
        self.statusMessage = statusMessage
        self.isAsync = isAsync
    }

    /// Why this handler never runs, or nil when it does.
    public var skipReason: String? {
        if type != "command" { return "「\(type)」类型的钩子不会运行（只运行 command）" }
        if isAsync { return "async 钩子不会运行" }
        if (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有 command" }
        return nil
    }
}

/// One handler of one matcher group, flattened, with where it came from.
public struct HookDefinition: Identifiable, Equatable, Sendable {
    /// `<plugin>:<source>:<event>:<group>:<handler>`, Codex's declaration key.
    public var id: String
    public var pluginID: String
    /// Plugin-relative file (`hooks/hooks.json`) or `plugin.json#hooks[0]`.
    public var source: String
    public var event: HookEvent
    public var matcher: String?
    public var handler: HookHandler
    /// Set when the matcher is not a valid regex; the hook never runs.
    public var matcherProblem: String?

    public var runs: Bool { handler.skipReason == nil && matcherProblem == nil && event.isTriggered }
}

/// A `matcher` value: empty, absent or `*` matches everything; a value made
/// only of letters, digits, `_` and `|` is a list of exact names; anything
/// else is an unanchored regex search (Codex `HookMatcher`).
public struct HookMatcher: Sendable {
    private enum Kind: @unchecked Sendable {
        case all
        case exact([String])
        case regex(NSRegularExpression)
    }

    private let kind: Kind

    public init(_ pattern: String?) throws {
        let pattern = pattern ?? ""
        if pattern.isEmpty || pattern == "*" {
            kind = .all
        } else if pattern.unicodeScalars.allSatisfy({ scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                || scalar == "_" || scalar == "|"
        }) {
            kind = .exact(pattern.split(separator: "|", omittingEmptySubsequences: false).map(String.init))
        } else {
            kind = .regex(try NSRegularExpression(pattern: pattern))
        }
    }

    /// True when any of `candidates` matches. No candidates only matches `all`.
    public func matches(_ candidates: [String]) -> Bool {
        switch kind {
        case .all:
            return true
        case .exact(let names):
            return candidates.contains { names.contains($0) }
        case .regex(let regex):
            return candidates.contains { candidate in
                regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }
        }
    }
}

public enum HooksFile {
    public enum ParseError: Error, Equatable, LocalizedError {
        case notJSON
        case wrongShape(String)

        public var errorDescription: String? {
            switch self {
            case .notJSON: "钩子文件不是合法的 JSON"
            case .wrongShape(let detail): "钩子文件格式不对：\(detail)"
            }
        }
    }

    /// Flattens `{"hooks": {Event: [{matcher, hooks: [...]}]}}`. Unknown
    /// events are skipped with a warning; a malformed group or handler
    /// fails the file, as Codex's typed parse does.
    public static func parse(_ data: Data, pluginID: String, source: String) throws -> (hooks: [HookDefinition], warnings: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw ParseError.notJSON }
        guard let root = object as? [String: Any] else { throw ParseError.wrongShape("顶层必须是对象") }
        return try parse(object: root, pluginID: pluginID, source: source)
    }

    static func parse(object root: [String: Any], pluginID: String, source: String) throws -> (hooks: [HookDefinition], warnings: [String]) {
        guard let value = root["hooks"] else { return ([], []) }
        guard let events = value as? [String: Any] else { throw ParseError.wrongShape("「hooks」必须是对象") }
        var hooks: [HookDefinition] = []
        var warnings: [String] = []
        // Codex's declaration order is the struct field order; keep the
        // documented event order, then file order inside each event.
        let known = Set(HookEvent.allCases.map(\.rawValue))
        for name in events.keys.sorted() where !known.contains(name) {
            warnings.append("\(source)：未知事件「\(name)」，已忽略")
        }
        for event in HookEvent.allCases {
            guard let rawGroups = events[event.rawValue] else { continue }
            guard let groups = rawGroups as? [Any] else {
                throw ParseError.wrongShape("「\(event.rawValue)」必须是数组")
            }
            for (groupIndex, rawGroup) in groups.enumerated() {
                guard let group = rawGroup as? [String: Any] else {
                    throw ParseError.wrongShape("「\(event.rawValue)」第 \(groupIndex + 1) 组必须是对象")
                }
                let matcher: String?
                switch group["matcher"] {
                case nil, is NSNull: matcher = nil
                case let text as String: matcher = text
                default: throw ParseError.wrongShape("「\(event.rawValue)」第 \(groupIndex + 1) 组的 matcher 必须是字符串")
                }
                var matcherProblem: String?
                if event.usesMatcher {
                    do { _ = try HookMatcher(matcher) } catch { matcherProblem = "matcher「\(matcher ?? "")」不是合法的正则表达式" }
                }
                guard let handlers = group["hooks"] as? [Any] else {
                    throw ParseError.wrongShape("「\(event.rawValue)」第 \(groupIndex + 1) 组缺少 hooks 数组")
                }
                for (handlerIndex, rawHandler) in handlers.enumerated() {
                    let handler = try parseHandler(rawHandler, where: "「\(event.rawValue)」第 \(groupIndex + 1) 组第 \(handlerIndex + 1) 个")
                    hooks.append(HookDefinition(
                        id: "\(pluginID):\(source):\(event.rawValue):\(groupIndex):\(handlerIndex)",
                        pluginID: pluginID, source: source, event: event,
                        matcher: event.usesMatcher ? matcher : nil,
                        handler: handler, matcherProblem: matcherProblem
                    ))
                }
            }
        }
        return (hooks, warnings)
    }

    private static func parseHandler(_ raw: Any, where location: String) throws -> HookHandler {
        guard let object = raw as? [String: Any] else { throw ParseError.wrongShape("\(location)钩子必须是对象") }
        guard let type = object["type"] as? String else { throw ParseError.wrongShape("\(location)钩子缺少 type") }
        func optionalString(_ key: String) throws -> String? {
            switch object[key] {
            case nil, is NSNull: return nil
            case let text as String: return text
            default: throw ParseError.wrongShape("\(location)钩子的 \(key) 必须是字符串")
            }
        }
        var timeout = HookHandler.defaultTimeout
        if let value = object["timeout"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue == number.doubleValue.rounded() else {
                throw ParseError.wrongShape("\(location)钩子的 timeout 必须是非负整数（秒）")
            }
            timeout = number.intValue
        }
        var isAsync = false
        if let value = object["async"], !(value is NSNull) {
            guard let flag = value as? Bool else { throw ParseError.wrongShape("\(location)钩子的 async 必须是布尔值") }
            isAsync = flag
        }
        return HookHandler(
            type: type,
            command: try optionalString("command"),
            timeout: timeout,
            statusMessage: try optionalString("statusMessage"),
            isAsync: isAsync
        )
    }
}
