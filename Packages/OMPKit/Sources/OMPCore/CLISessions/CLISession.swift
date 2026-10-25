import Foundation

/// One running (or stopped) coding-agent session on the Mac, as seen by the
/// phone. Populated from the agent's own machine-readable listing — never
/// invented. A session the listing does not mention simply does not exist here.
public struct CLISession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Which binary owns it: `claude`, `codex`, `omp`, …
    public var agent: String
    /// The agent's own label for the session, when it has one.
    public var name: String?
    public var cwd: String
    /// The agent's own state word (`running`, `blocked`, `idle`, …), kept
    /// verbatim so the phone shows what the agent actually reports.
    public var state: String
    public var startedAt: Date?
    public var sessionID: String?
    /// `background` (detached, controllable by id) or `interactive` (running
    /// in someone's terminal). Optional for wire compatibility.
    public var kind: String?
    /// Interactive sessions report their process id.
    public var pid: Int?

    public init(
        id: String,
        agent: String,
        name: String? = nil,
        cwd: String,
        state: String,
        startedAt: Date? = nil,
        sessionID: String? = nil,
        kind: String? = nil,
        pid: Int? = nil
    ) {
        self.id = id
        self.agent = agent
        self.name = name
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.kind = kind
        self.pid = pid
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, name, cwd, state, startedAt, sessionID, kind, pid
    }

    /// `startedAt` travels as an ISO8601 string via `RelayDate`, like every
    /// other date in the host RPC. Synthesized `Date` coding is a bare number,
    /// which the RPC clients' `.iso8601` decoders reject — the whole response
    /// then fails to decode and the phone shows "读取失败".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cwd = try c.decode(String.self, forKey: .cwd)
        state = try c.decode(String.self, forKey: .state)
        if let raw = try c.decodeIfPresent(String.self, forKey: .startedAt) {
            startedAt = RelayDate.date(from: raw)
        } else {
            startedAt = nil
        }
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(state, forKey: .state)
        if let startedAt { try c.encode(RelayDate.string(from: startedAt), forKey: .startedAt) }
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(pid, forKey: .pid)
    }

    /// Only background sessions can be stopped/removed/tailed by id. An
    /// interactive one lives in a terminal tab; the phone shows it but does
    /// not reach into that terminal.
    public var isControllable: Bool { kind == "background" }

    /// Directory name of `cwd`, for a compact row label.
    public var directoryName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// What the phone is allowed to do to a session. `start` creates a new one;
/// the rest act on an existing id.
public enum CLISessionAction: String, Codable, Sendable, CaseIterable {
    case start
    case stop
    case remove
    case logs
}

/// One agent's machine-readable session listing, turned into `CLISession`s.
///
/// Each agent has its own CLI shape, so the parser lives next to the model and
/// is unit-tested against captured output rather than against a live binary.
public enum CLISessionListing {
    /// `claude agents --json`: an array of objects. Background rows carry a
    /// short `id` and `state`; interactive rows (sessions open in a terminal)
    /// carry `pid`, `status` and only the full `sessionId`. Unknown fields are
    /// ignored, and a row with neither id nor a `cwd` is dropped, not guessed.
    public static func claude(json data: Data) -> [CLISession] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            let shortID = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let sessionID = (row["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let id = shortID ?? sessionID,
                  let cwd = row["cwd"] as? String, !cwd.isEmpty else { return nil }
            let started = (row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return CLISession(
                id: id,
                agent: "claude",
                name: row["name"] as? String,
                cwd: cwd,
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "unknown",
                startedAt: started,
                sessionID: sessionID,
                kind: row["kind"] as? String,
                pid: row["pid"] as? Int
            )
        }
    }

    /// The argv for an action, or `nil` when the agent does not support it.
    /// `prompt` is only used by `start`.
    public static func command(agent: String, action: CLISessionAction, id: String?, prompt: String?) -> [String]? {
        switch agent {
        case "claude":
            switch action {
            case .start:
                let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty else { return nil }
                return ["claude", "--bg", trimmed]
            case .stop:
                guard let id else { return nil }
                return ["claude", "stop", id]
            case .remove:
                guard let id else { return nil }
                return ["claude", "rm", id]
            case .logs:
                guard let id else { return nil }
                return ["claude", "logs", id]
            }
        default:
            return nil
        }
    }
}
