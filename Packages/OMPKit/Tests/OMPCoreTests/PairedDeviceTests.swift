import XCTest
@testable import OMPCore

final class PairedDeviceTests: XCTestCase {
    func testUpsertRefreshesSameEndpointAndKeepsItsID() {
        var list: [PairedDevice] = []
        let first = PairedDevice(name: "Mac A", transport: .lan, host: "192.168.1.8", port: 8795, token: "t1",
                                 lastConnectedAt: Date(timeIntervalSince1970: 100))
        list.upsert(first)
        var again = first
        again.id = UUID()
        again.name = "Mac A (renamed)"
        again.token = "t2"
        again.lastConnectedAt = Date(timeIntervalSince1970: 200)
        list.upsert(again)
        XCTAssertEqual(list.count, 1, "同一地址重复配对应更新而不是新增")
        XCTAssertEqual(list[0].id, first.id)
        XCTAssertEqual(list[0].name, "Mac A (renamed)")
        XCTAssertEqual(list[0].token, "t2")
    }

    func testEndpointKeyIsCaseInsensitiveAndTransportAware() {
        let lan = PairedDevice(name: "x", transport: .lan, host: "Mac.LOCAL", port: 8790)
        let lanLower = PairedDevice(name: "y", transport: .lan, host: "mac.local", port: 8790)
        let otherPort = PairedDevice(name: "z", transport: .lan, host: "mac.local", port: 8795)
        let room = PairedDevice(name: "r", transport: .room, hubURL: "https://Hub.example", roomCode: "abc123")
        let roomUpper = PairedDevice(name: "r2", transport: .room, hubURL: "https://hub.example", roomCode: "ABC123")
        XCTAssertEqual(lan.endpointKey, lanLower.endpointKey)
        XCTAssertNotEqual(lan.endpointKey, otherPort.endpointKey)
        XCTAssertEqual(room.endpointKey, roomUpper.endpointKey)
        XCTAssertNotEqual(lan.endpointKey, room.endpointKey)
    }

    func testListIsOrderedMostRecentFirst() {
        var list: [PairedDevice] = []
        list.upsert(PairedDevice(name: "old", transport: .lan, host: "a", lastConnectedAt: Date(timeIntervalSince1970: 10)))
        list.upsert(PairedDevice(name: "new", transport: .lan, host: "b", lastConnectedAt: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(list.map(\.name), ["new", "old"])
    }

    func testSettingsWithoutTheKeyDecodeAsEmptyAndRoundTrip() throws {
        let legacy = Data(#"{"version":1,"remoteHost":"1.2.3.4"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.pairedDevices, [])

        var settings = AppSettings()
        settings.pairedDevices.upsert(PairedDevice(name: "Mac", transport: .room, hubURL: "https://h", roomCode: "ABC123",
                                                   lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.pairedDevices, settings.pairedDevices)
    }
}
