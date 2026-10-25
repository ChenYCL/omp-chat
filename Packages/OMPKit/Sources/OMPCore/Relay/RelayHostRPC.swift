import Foundation

/// One host-RPC request. `op` is `"info" | "fs.list" | "fs.read" | "exec"`.
///
/// Dates travel as ISO8601 via [`RelayDate`]. `info` is always allowed;
/// `fs.list`, `fs.read`, and `exec` run only when the host setting
/// `AppSettings.relayAllowShell` is true, otherwise the host answers
/// `ok: false, error: "shell_disabled"`.
public struct HostRPCRequest: Codable, Sendable, Equatable {
    public var id: String
    public var op: String
    public var path: String?
    public var command: String?
    public var cwd: String?
    public var maxBytes: Int?
    public var timeout: Double?

    public init(
        id: String,
        op: String,
        path: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        maxBytes: Int? = nil,
        timeout: Double? = nil
    ) {
        self.id = id
        self.op = op
        self.path = path
        self.command = command
        self.cwd = cwd
        self.maxBytes = maxBytes
        self.timeout = timeout
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
        info: HostInfo? = nil
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
    }
}

/// Transport-agnostic host RPC, so the remote panes work identically over LAN
/// (`RemoteRelayClient`) and the hub (`RelayHubClient`).
public protocol RelayRPCSink: Sendable {
    func call(_ request: HostRPCRequest) async throws -> HostRPCResponse
}
