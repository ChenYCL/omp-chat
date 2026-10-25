import SwiftUI
import OMPCore


/// The one live link between the phone and the paired Mac.
///
/// `RemoteScreen` publishes whichever transport it connected (`RemoteRelayClient`
/// over LAN, `RelayHubClient` over a room code) into `sink`; every host pane
/// reads through it. Nothing here is invented: with `sink == nil` the panes
/// show an honest "未连接" state instead of demo data.
@MainActor
@Observable
public final class RemoteSession {
    /// The live transport, or nil while the phone is unpaired.
    public var sink: (any RelayRPCSink & RelayCommandSink)?
    /// Display name reported by the host's `/pair` or snapshot.
    public var hostName: String
    /// True only while a pairing is actually up.
    public var isConnected: Bool
    /// Last `info` answer from the host; nil until one succeeds.
    public var info: HostInfo?
    /// How the current sink was opened, so the config pane can say which.
    public var mode: Mode

    public enum Mode: String, Sendable {
        case none = "未连接"
        case lan = "局域网"
        case room = "房间码"
    }

    public init() {
        sink = nil
        hostName = ""
        isConnected = false
        info = nil
        mode = .none
    }

    /// Publishes a freshly paired transport. Called from the 远程 tab on connect.
    public func attach(
        sink: any RelayRPCSink & RelayCommandSink,
        hostName: String,
        mode: Mode
    ) {
        self.sink = sink
        self.hostName = hostName
        self.mode = mode
        isConnected = true
    }

    /// Drops the transport. Called from the 远程 tab on disconnect.
    public func detach() {
        sink = nil
        hostName = ""
        isConnected = false
        info = nil
        mode = .none
    }
}

enum HostRPC {
    /// Sends `request`. `id` overrides the fresh request id (the terminal
    /// pane pins it so Ctrl-C can cancel that exact exec); the default keeps
    /// the old behavior. Throws only when nothing came back at all; an
    /// `ok: false` body is returned as-is.
    static func call(
        _ sink: any RelayRPCSink,
        op: String,
        id: String? = nil,
        path: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        maxBytes: Int? = nil,
        timeout: Double? = nil,
        requestID: String? = nil
    ) async throws -> HostRPCResponse {
        let request = HostRPCRequest(
            id: id ?? UUID().uuidString,
            op: op,
            path: path,
            command: command,
            cwd: cwd,
            maxBytes: maxBytes,
            timeout: timeout,
            requestID: requestID
        )
        return try await sink.call(request)
    }

    /// What an `ok: false` answer should say to a person.
    static func message(for response: HostRPCResponse) -> String {
        switch response.error {
        case "shell_disabled":
            return "在 Mac 的 设置→远程控制 打开 允许手机访问文件与终端"
        case "not_found":
            return "路径不存在"
        case "timeout":
            return "命令超时"
        case "bad_request":
            return "请求无效"
        case "unsupported":
            return "这台 Mac 还不支持远程操作"
        case let other?:
            return other
        case nil:
            return "主机拒绝了这次操作"
        }
    }
}

/// Strips ANSI colour / cursor sequences so terminal output is plain text.
enum ANSIStripping {
    static func strip(_ raw: String) -> String {
        guard raw.contains("\u{1B}") || raw.contains("\u{9B}") else { return raw }
        var output = ""
        output.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\u{1B}" || character == "\u{9B}" {
                let body = raw.index(after: index)
                if character == "\u{1B}", body < raw.endIndex, raw[body] == "[" {
                    index = raw.index(after: body)
                } else if character == "\u{1B}" {
                    index = body < raw.endIndex ? raw.index(after: body) : body
                    continue
                } else {
                    index = body
                }
                while index < raw.endIndex {
                    let byte = raw[index]
                    index = raw.index(after: index)
                    if byte >= "@" && byte <= "~" { break }
                }
            } else {
                output.append(character)
                index = raw.index(after: index)
            }
        }
        return output
    }
}
