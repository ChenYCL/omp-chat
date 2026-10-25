import Foundation
import OMPCore

/// Whether a saved Mac answers right now, for the 可控设备 list.
///
/// The result is only ever what a real request returned: a LAN device must
/// accept its token on `/pair`, a room-code device must have a snapshot on the
/// hub. Anything else — timeout, refusal, bad token — is `offline`, with the
/// reason kept so the row can say why.
public enum DeviceReachability: Equatable, Sendable {
    case checking
    case online
    case offline(String)

    public typealias Probe = @Sendable (PairedDevice) async throws -> Void

    /// Real probe: one cheap read per transport. It never sends commands.
    public static let live: Probe = { device in
        switch device.transport {
        case .lan:
            _ = try await RemoteRelayClient(host: device.host, port: device.port, token: device.token).pair()
        case .room:
            guard let url = URL(string: device.hubURL) else { throw RelayHubError.badHubURL }
            _ = try await RelayHubClient(hubURL: url, roomCode: device.roomCode).snapshot()
        }
    }

    /// Probes every device concurrently, each bounded by `timeout`, and
    /// reports each result as soon as it lands.
    public static func check(
        _ devices: [PairedDevice],
        timeout: Duration = .seconds(4),
        probe: @escaping Probe = live,
        onResult: @escaping @Sendable (UUID, DeviceReachability) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask {
                    await onResult(device.id, await state(of: device, timeout: timeout, probe: probe))
                }
            }
        }
    }

    static func state(of device: PairedDevice, timeout: Duration, probe: @escaping Probe) async -> DeviceReachability {
        await withTaskGroup(of: DeviceReachability.self) { group in
            group.addTask {
                do {
                    try await probe(device)
                    return .online
                } catch {
                    return .offline(describe(error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .offline("超时")
            }
            let first = await group.next() ?? .offline("未知")
            group.cancelAll()
            return first
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "超时"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "连不上"
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
