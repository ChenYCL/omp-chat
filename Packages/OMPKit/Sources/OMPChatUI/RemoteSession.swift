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

    /// When the last snapshot arrived, so diagnostics can report its age.
    public var lastSnapshotAt: Date?
    /// Which saved Mac the live link belongs to.
    public var activeDeviceID: UUID?
    /// Set by the 可控设备 list; the 远程 tab consumes it by reconnecting to
    /// that Mac, then clears it.
    public var requestedDevice: PairedDevice?
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
        lastSnapshotAt = nil
        activeDeviceID = nil
        requestedDevice = nil
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
        lastSnapshotAt = Date()
    }
    /// Records that a snapshot just arrived.
    public func noteSnapshot() {
        lastSnapshotAt = Date()
    }


    /// Drops the transport. Called from the 远程 tab on disconnect.
    public func detach() {
        sink = nil
        hostName = ""
        isConnected = false
        info = nil
        mode = .none
        lastSnapshotAt = nil
        activeDeviceID = nil
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
        requestID: String? = nil,
        background: Bool? = nil,
        offset: Int? = nil,
        prompt: String? = nil,
        wait: Double? = nil
    ) async throws -> HostRPCResponse {
        let request = HostRPCRequest(
            id: id ?? UUID().uuidString,
            op: op,
            path: path,
            command: command,
            cwd: cwd,
            maxBytes: maxBytes,
            timeout: timeout,
            requestID: requestID,
            background: background,
            offset: offset,
            prompt: prompt,
            wait: wait
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
        case "too_large":
            return "内容超过 256 KB，无法保存"
        case "unsupported":
            return "这台 Mac 还不支持远程操作"
        case "workspace_not_trusted":
            return "这个目录还没在 Claude Code 里确认过信任：先在 Mac 上用 claude 进入该目录并接受信任提示"
        case "command_failed":
            return "命令执行失败"
        case let other?:
            return other
        case nil:
            return "主机拒绝了这次操作"
        }
    }
    /// One decoded `exec.poll` answer: the appended chunk plus stream state.
    ///
    /// `text` is the output appended since `offset` (stdout and stderr merged
    /// in arrival order, UTF-8 safe at chunk edges); `nextOffset` is what the
    /// next poll must pass. On `done` the host also answers `exitCode` and the
    /// cd-tracked `cwd`. An `ok: false` answer carries its `error` instead.
    struct ProcessedPoll {
        let text: String
        let nextOffset: Int
        let done: Bool
        let exitCode: Int?
        let cwd: String?
        let truncated: Bool
        /// Host refusal reason (`"shell_disabled" | "not_found" | …`), nil on success.
        let error: String?

        init(response: HostRPCResponse) {
            text = response.text ?? ""
            nextOffset = response.nextOffset ?? 0
            done = response.done ?? false
            exitCode = response.exitCode
            cwd = response.cwd
            truncated = response.truncated ?? false
            error = response.ok ? nil : response.error
        }

        /// True when the host predates `exec.poll`: iOS stubs answer
        /// `unsupported`, an old macOS host answers an unknown op with
        /// `bad_request`, and a stripped/relayed hop may say `not_found`.
        var hostLacksPoll: Bool {
            error == "unsupported" || error == "bad_request" || error == "not_found"
        }
    }

    /// Decodes one `exec.poll` answer; see [`ProcessedPoll`].
    static func decodePoll(_ response: HostRPCResponse) -> ProcessedPoll {
        ProcessedPoll(response: response)
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

/// Phone-side state of the answers to the Mac's approval cards.
///
/// A relay command gets no reply over the LAN route or the hub, so the
/// outcome is read from later snapshots: the card leaves `approvals` once the
/// Mac applied the answer, or `commandFailures` names the request when the
/// Mac refused it. An answer that hears neither within `timeout` is given up
/// on, so the buttons never stay disabled for good.
struct RemoteApprovalTracker: Equatable {
    /// How long an answer may stay unconfirmed before the card is usable again.
    static let timeout: TimeInterval = 15
    /// Why 允许一次 is off when the Mac's phone-access switch is off.
    static let shellDisabledMessage = "在 Mac 的 设置 → 远程控制 里打开「允许手机访问文件与终端」才能在手机上批准"

    private struct Answer: Equatable {
        let requestID: String
        let sentAt: Date
    }

    /// Answers on their way, by approval id.
    private var pending: [String: Answer] = [:]
    /// Why the last answer to a card did not apply, by approval id.
    private var errors: [String: String] = [:]

    /// True while an answer to the card is on its way.
    func isSending(_ approvalID: String) -> Bool { pending[approvalID] != nil }

    /// Why the last answer to the card did not apply; nil otherwise.
    func error(for approvalID: String) -> String? { errors[approvalID] }

    /// When the oldest unconfirmed answer gives up; nil when none is pending.
    var nextDeadline: Date? {
        pending.values.map { $0.sentAt.addingTimeInterval(Self.timeout) }.min()
    }

    /// Starts answering a card. Returns the request id to send with the
    /// command, or nil while an answer to that card is already on its way.
    mutating func begin(_ approvalID: String, requestID: String = UUID().uuidString, now: Date = Date()) -> String? {
        guard pending[approvalID] == nil else { return nil }
        pending[approvalID] = Answer(requestID: requestID, sentAt: now)
        errors[approvalID] = nil
        return requestID
    }

    /// The command never reached the Mac; the card is usable again.
    mutating func sendFailed(_ approvalID: String, message: String) {
        pending[approvalID] = nil
        errors[approvalID] = message
    }

    /// Reconciles with the latest snapshot. Returns what to tell the user about
    /// refused answers whose card is already gone (answered on the Mac first).
    mutating func update(
        approvals: [RelayApproval], failures: [RelayCommandFailure], now: Date = Date()
    ) -> [String] {
        let listed = Set(approvals.map(\.id))
        let refusals = Dictionary(failures.map { ($0.requestID, $0.error) }) { _, latest in latest }
        var notices: [String] = []
        for (approvalID, answer) in pending {
            if let refusal = refusals[answer.requestID] {
                pending[approvalID] = nil
                if listed.contains(approvalID) {
                    errors[approvalID] = Self.message(for: refusal)
                } else {
                    notices.append(Self.message(for: refusal))
                }
            } else if !listed.contains(approvalID) {
                pending[approvalID] = nil
            } else if now.timeIntervalSince(answer.sentAt) >= Self.timeout {
                pending[approvalID] = nil
                errors[approvalID] = "Mac 没有回应，请重试"
            }
        }
        errors = errors.filter { listed.contains($0.key) }
        return notices
    }

    /// What a refusal code in `commandFailures` should say to a person.
    static func message(for error: String) -> String {
        switch error {
        case "shell_disabled": shellDisabledMessage
        case "not_found": "这张卡片已经在别处处理了"
        default: "Mac 没有执行这次批准（\(error)）"
        }
    }

    /// What to say when the answer never reached the Mac. A `400` means the
    /// Mac or the hub predates answering approvals from the phone.
    static func sendFailureMessage(_ error: Error) -> String {
        if case .http(400)? = error as? RelayClientError { return "这台 Mac 还不支持在手机上批准，请先更新" }
        if case .http(400)? = error as? RelayHubError { return "这台 Mac 或中继还不支持在手机上批准，请先更新" }
        return "发送失败，稍后重试"
    }
}
