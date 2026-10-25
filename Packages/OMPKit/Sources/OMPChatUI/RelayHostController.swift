import Foundation
import OMPCore

/// macOS-side glue between [`ChatAppModel`] and the LAN relay: pushes
/// throttled snapshots into the [`RelayServer`] and feeds remote commands
/// back into the model.
///
/// The controller is a pure `@MainActor` object; the heavy lifting (HTTP,
/// Bonjour, connection I/O) lives in `OMPCore`'s relay types.
@MainActor
public final class RelayHostController {
    /// Model is weak so the controller can outlive the app's model without
    /// keeping it (and its workspace) alive.
    private weak var model: ChatAppModel?

    private let server = RelayServer()
    /// Rebuilt after every server start: attached mode captures the server's
    /// listener at construction time and `server.start` replaces it.
    private var advertiser: RelayAdvertiser?

    /// Minimum interval between snapshot pushes while idle.
    private let idleInterval: TimeInterval = 0.5
    /// Minimum interval between snapshot pushes while a reply is streaming.
    private let streamingInterval: TimeInterval = 1.0

    private var pushTimer: Timer?
    private var lastPushAt = Date.distantPast

    /// Cross-network mode: when a hub URL is configured both the LAN server and
    /// the hub publisher run, so the phone can connect either way.
    private var hubClient: RelayHubClient?
    private var hubPublishTask: Task<Void, Never>?

    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Hub-specific failure (LAN relay may still be healthy).
    public private(set) var hubError: String?

    /// Listen port while running; `nil` when stopped.
    public var port: UInt16? { isRunning ? server.port : nil }

    /// Pairing token handed out to remote controllers (LAN mode).
    public private(set) var token: String

    /// Room code for the public relay hub; `nil` when hub mode is off.
    public private(set) var roomCode: String?

    /// Hub base URL while hub mode is on.
    public private(set) var hubURL: URL?

    public init(model: ChatAppModel, token: String) {
        self.model = model
        self.token = token
        server.onInput = { [weak self] command in
            await self?.model?.handleRelayCommand(command)
        }
    }

    deinit {
        pushTimer?.invalidate()
    }

    /// Starts the HTTP relay and Bonjour advertisement. Idempotent; a running
    /// controller is restarted only when the port changed. Bonjour failure is
    /// non-fatal: direct `IP:port` access keeps working and the reason lands
    /// in `lastError`.
    public func start(port: UInt16) {
        let effectivePort = port == 0 ? 8790 : port
        if isRunning, server.port == effectivePort { return }
        stop()
        do {
            try server.start(port: effectivePort, token: token)
        } catch {
            isRunning = false
            lastError = relayErrorDescription(error)
            return
        }

        isRunning = true
        lastError = nil
        let advertiser = RelayAdvertiser(attachedTo: server)
        self.advertiser = advertiser
        #if os(macOS)
        let advertiseName = Host.current().localizedName ?? "OMPChat"
        #else
        let advertiseName = "OMPChat"
        #endif
        do {
            try advertiser.start(name: advertiseName, port: server.port)
        } catch {
            lastError = "局域网发现不可用（\(relayErrorDescription(error))），仍可通过 IP:端口直连"
        }

        pushTimer?.invalidate()
        let timer = Timer(timeInterval: idleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pushSnapshotIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pushTimer = timer
        pushSnapshotIfDue(force: true)
    }

    /// Adds cross-network reachability on top of the LAN relay: register the
    /// room with the hub and keep pushing snapshots upstream.
    public func startHub(roomCode: String, hubURL: URL) {
        stopHub()
        self.roomCode = roomCode.uppercased()
        self.hubURL = hubURL
        hubError = nil
        let client = RelayHubClient(hubURL: hubURL, roomCode: roomCode)
        hubClient = client
        do {
            try client.startHost { [weak self] command in
                await self?.model?.handleRelayCommand(command)
            }
        } catch {
            hubError = "中继连接失败：\(relayErrorDescription(error))"
            hubClient = nil
            return
        }
        hubPublishTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.hubClient, let model = self.model else { break }
                do {
                    try await client.publish(model.relaySnapshot())
                    self.hubError = nil
                } catch {
                    self.hubError = "状态上报失败：\(self.relayErrorDescription(error))"
                }
                let interval = model.isStreaming ? UInt64(800_000_000) : UInt64(2_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Drops the hub registration; the LAN server (if running) is untouched.
    public func stopHub() {
        hubPublishTask?.cancel()
        hubPublishTask = nil
        hubClient?.stopHost()
        hubClient = nil
        roomCode = nil
        hubURL = nil
    }

    /// Stops the relay, the Bonjour advertisement and the push timer.
    public func stop() {
        pushTimer?.invalidate()
        pushTimer = nil
        advertiser?.stop()
        advertiser = nil
        server.stop()
        stopHub()
        isRunning = false
    }

    /// Refreshes the pairing token (takes effect on next start).
    public func updateToken(_ newToken: String) {
        token = newToken
    }

    /// Timer tick: push a snapshot when the throttle window has elapsed, or
    /// immediately when the model flipped into/out of streaming.
    private func pushSnapshotIfDue(force: Bool = false) {
        guard isRunning, let model else { return }
        let interval = model.isStreaming ? streamingInterval : idleInterval
        let due = force || Date().timeIntervalSince(lastPushAt) >= interval
        guard due else { return }
        lastPushAt = Date()
        server.update(model.relaySnapshot())
    }

    private func relayErrorDescription(_ error: Error) -> String {
        if let advertiserError = error as? RelayAdvertiserError {
            switch advertiserError {
            case .notAttached: return "无法附加 Bonjour 服务"
            case .portMismatch: return "端口与服务器监听端口不一致"
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}

