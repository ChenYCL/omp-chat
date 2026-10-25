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
