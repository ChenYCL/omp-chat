import Foundation

/// A Mac this phone has successfully paired with, remembered so the phone can
/// switch between several Macs without retyping tokens or room codes.
///
/// Only devices that completed a real pairing are ever stored; the list is
/// written from the pairing success path, never pre-filled.
public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    public enum Transport: String, Codable, Sendable {
        case lan
        case room
    }

    public var id: UUID
    /// Host name the Mac reported when pairing (`/pair`).
    public var name: String
    public var transport: Transport
    /// LAN: address, port and pairing token.
    public var host: String
    public var port: UInt16
    public var token: String
    /// Room code transport: hub base URL and the 6-character room.
    public var hubURL: String
    public var roomCode: String
    public var lastConnectedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        host: String = "",
        port: UInt16 = 8790,
        token: String = "",
        hubURL: String = "",
        roomCode: String = "",
        lastConnectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.port = port
        self.token = token
        self.hubURL = hubURL
        self.roomCode = roomCode
        self.lastConnectedAt = lastConnectedAt
    }

    /// What makes two entries the same endpoint. Re-pairing the same Mac
    /// updates its row instead of adding a second one.
    public var endpointKey: String {
        switch transport {
        case .lan: "lan|\(host.lowercased())|\(port)"
        case .room: "room|\(hubURL.lowercased())|\(roomCode.uppercased())"
        }
    }

    /// One-line description of how it is reached, for list rows.
    public var detail: String {
        switch transport {
        case .lan: "局域网 · \(host):\(port)"
        case .room: "房间码 · \(roomCode.uppercased())"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transport, host, port, token, hubURL, roomCode, lastConnectedAt
    }

    /// `lastConnectedAt` rides as ISO8601 (second precision) like every other
    /// persisted date here; all other keys fall back to defaults so a row
    /// written by an older build still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .lan
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8790
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        hubURL = try c.decodeIfPresent(String.self, forKey: .hubURL) ?? ""
        roomCode = try c.decodeIfPresent(String.self, forKey: .roomCode) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .lastConnectedAt),
           let date = RelayDate.date(from: raw) {
            lastConnectedAt = date
        } else {
            lastConnectedAt = Date(timeIntervalSince1970: 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(token, forKey: .token)
        try c.encode(hubURL, forKey: .hubURL)
        try c.encode(roomCode, forKey: .roomCode)
        try c.encode(RelayDate.string(from: lastConnectedAt), forKey: .lastConnectedAt)
    }
}

extension Array where Element == PairedDevice {
    /// Inserts `device`, or refreshes the existing row for the same endpoint
    /// (keeping its id), then orders most recently connected first.
    public mutating func upsert(_ device: PairedDevice) {
        if let index = firstIndex(where: { $0.endpointKey == device.endpointKey }) {
            var merged = device
            merged.id = self[index].id
            self[index] = merged
        } else {
            append(device)
        }
        sort { $0.lastConnectedAt > $1.lastConnectedAt }
    }
}

/// Keeps pairing tokens out of `workspace.json`.
///
/// The settings document stores devices with an empty `token`; the real value
/// lives in the secret store under one account per device. A token is only
/// dropped from the document once the vault write succeeded, so a failing
/// vault degrades to the old plaintext behaviour instead of losing the token.
public enum PairedDeviceVault {
    public static func account(for id: UUID) -> String { "paired-device.\(id.uuidString)" }

    /// Fills each device's token from the vault. A token still sitting in the
    /// document (written by an earlier build) is moved into the vault, and
    /// `needsRewrite` tells the caller to save the document without it.
    public static func hydrate(
        _ devices: [PairedDevice],
        secrets: any SecretStoring
    ) -> (devices: [PairedDevice], needsRewrite: Bool) {
        var needsRewrite = false
        let hydrated = devices.map { device -> PairedDevice in
            var device = device
            if !device.token.isEmpty {
                // A token in the document is either from an older build or was
                // kept there because a vault write failed — both mean it is the
                // newest value, so it wins over whatever the vault holds.
                if (try? secrets.setSecret(device.token, for: account(for: device.id))) != nil {
                    needsRewrite = true
                }
            } else if let saved = (try? secrets.secret(for: account(for: device.id))) ?? nil {
                device.token = saved
            }
            return device
        }
        return (hydrated, needsRewrite)
    }

    /// Writes every token to the vault, drops vault entries of devices that
    /// were forgotten, and returns the devices as they should be persisted.
    public static func persistable(
        _ devices: [PairedDevice],
        previous: [PairedDevice],
        secrets: any SecretStoring
    ) -> [PairedDevice] {
        let kept = Set(devices.map(\.id))
        for gone in previous where !kept.contains(gone.id) {
            try? secrets.setSecret(nil, for: account(for: gone.id))
        }
        return devices.map { device in
            var device = device
            guard !device.token.isEmpty else { return device }
            if (try? secrets.setSecret(device.token, for: account(for: device.id))) != nil {
                device.token = ""
            }
            return device
        }
    }
}

extension AppSettings {
    /// Folds the pre-device-list connection (`remoteHost/Port/Token`) into
    /// `pairedDevices` and clears the plaintext token field. Returns true when
    /// the document changed and must be saved.
    public mutating func foldLegacyConnection() -> Bool {
        guard !remoteToken.isEmpty else { return false }
        if !remoteHost.isEmpty {
            let legacy = PairedDevice(
                name: remoteHost, transport: .lan, host: remoteHost, port: remotePort, token: remoteToken,
                lastConnectedAt: Date(timeIntervalSince1970: 0)
            )
            // A device already saved for this endpoint keeps its own (newer) row.
            if !pairedDevices.contains(where: { $0.endpointKey == legacy.endpointKey }) {
                pairedDevices.upsert(legacy)
            }
        }
        remoteToken = ""
        return true
    }
}
