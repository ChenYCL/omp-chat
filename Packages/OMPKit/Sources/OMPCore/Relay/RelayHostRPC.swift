import Foundation

/// One host-RPC request. `op` is `"info" | "fs.list" | "fs.read" | "exec" |
/// "exec.cancel" | "exec.poll"`.
///
/// Dates travel as ISO8601 via [`RelayDate`]. `info` is always allowed;
/// `fs.list`, `fs.read`, and `exec` run only when the host setting
/// `AppSettings.relayAllowShell` is true, otherwise the host answers
/// `ok: false, error: "shell_disabled"`. `exec.cancel` follows the same gate
/// and carries `requestID`: the `id` of the in-flight `exec` to stop. The
/// same two keys drive `exec.poll`, which reads a background `exec`'s output.
public struct HostRPCRequest: Codable, Sendable, Equatable {
    public var id: String
    public var op: String
    public var path: String?
    public var command: String?
    public var cwd: String?
    /// `exec` only: run without waiting for completion. The host answers
    /// immediately with `text: "started"`; output arrives via `exec.poll`.
    /// Old requests without the key decode as `nil` (blocking, as before).
    public var background: Bool?
    /// `exec.cancel` and `exec.poll` only: the `id` of the `exec` run to
    /// stop or read. Old documents without the key decode as `nil`.
    public var requestID: String?
    /// `exec.poll` only: bytes of the combined output the caller already has.
    public var offset: Int?
    public var maxBytes: Int?
    public var timeout: Double?
    /// `cli.control` only: the action (`start`/`stop`/`remove`/`logs`) goes in
    /// `path`, the agent name in `command`, the session id in `requestID`,
    /// and the prompt for a new session here.
    public var prompt: String?

    public init(
        id: String,
        op: String,
        path: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        maxBytes: Int? = nil,
        timeout: Double? = nil,
        requestID: String? = nil,
        background: Bool? = nil,
        offset: Int? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.op = op
        self.path = path
        self.command = command
        self.cwd = cwd
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.requestID = requestID
        self.background = background
        self.offset = offset
        self.prompt = prompt
    }
}

/// One directory entry from `fs.list`. `modified` is ISO8601 on the wire.
public struct HostFSEntry: Codable, Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int?
    public var modified: Date?

    public init(name: String, isDirectory: Bool, size: Int? = nil, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    private enum CodingKeys: String, CodingKey {
        case name, isDirectory, size, modified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        if let raw = try container.decodeIfPresent(String.self, forKey: .modified) {
            modified = RelayDate.date(from: raw)
        } else {
            modified = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encodeIfPresent(size, forKey: .size)
        if let modified {
            try container.encode(RelayDate.string(from: modified), forKey: .modified)
        }
    }
}

/// Identity of the paired Mac: who, where, and the git state of `cwd`.
public struct HostInfo: Codable, Sendable, Equatable {
    public var hostName: String
    public var user: String
    public var home: String
    public var cwd: String
    public var gitBranch: String?
    public var gitDirty: Int?

    public init(
        hostName: String,
        user: String,
        home: String,
        cwd: String,
        gitBranch: String? = nil,
        gitDirty: Int? = nil
    ) {
        self.hostName = hostName
        self.user = user
        self.home = home
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.gitDirty = gitDirty
    }
}

/// One host-RPC answer. HTTP is `200` even when `ok` is false.
///
/// `error` is one of `"shell_disabled" | "not_found" | "timeout" |
/// "bad_request" | "unsupported"`, or free text. `exec` returns `stdout`,
/// `stderr`, `exitCode`, and the resulting `cwd` (a `cd` sticks because the
/// client passes `cwd` back on the next call). `fs.read` returns `text`.
/// A background `exec` returns `text: "started"`; `exec.poll` returns the
/// output appended since `offset` as `text`, the cursor as `nextOffset`,
/// `done` when the run has finished, and — once done — `exitCode` plus the
/// cd-tracked `cwd`.
public struct HostRPCResponse: Codable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var error: String?
    public var entries: [HostFSEntry]?
    public var text: String?
    public var truncated: Bool?
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int?
    public var cwd: String?
    public var info: HostInfo?
    /// `exec.poll` only: caller's next byte offset into the combined output.
    public var nextOffset: Int?
    /// `exec.poll` only: true once the run has finished and the final
    /// `exitCode` and `cwd` are attached.
    public var done: Bool?
    /// `cli.sessions` only: the coding-agent sessions the Mac is running.
    /// Optional so hosts and clients built before this field still decode.
    public var sessions: [CLISession]?

    public init(
        id: String,
        ok: Bool,
        error: String? = nil,
        entries: [HostFSEntry]? = nil,
        text: String? = nil,
        truncated: Bool? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int? = nil,
        cwd: String? = nil,
        info: HostInfo? = nil,
        nextOffset: Int? = nil,
        done: Bool? = nil,
        sessions: [CLISession]? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.entries = entries
        self.text = text
        self.truncated = truncated
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.cwd = cwd
        self.info = info
        self.nextOffset = nextOffset
        self.done = done
        self.sessions = sessions
    }
}

/// Transport-agnostic host RPC, so the remote panes work identically over LAN
/// (`RemoteRelayClient`) and the hub (`RelayHubClient`).
public protocol RelayRPCSink: Sendable {
    func call(_ request: HostRPCRequest) async throws -> HostRPCResponse
}
