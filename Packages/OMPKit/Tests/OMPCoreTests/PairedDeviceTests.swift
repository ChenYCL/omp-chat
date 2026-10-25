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

final class LegacyConnectionTests: XCTestCase {
    func testLegacyTokenBecomesADeviceAndTheFieldIsCleared() {
        var settings = AppSettings(remoteHost: "mac.local", remotePort: 8795, remoteToken: "old")
        XCTAssertTrue(settings.foldLegacyConnection())
        XCTAssertEqual(settings.remoteToken, "")
        XCTAssertEqual(settings.pairedDevices.map(\.host), ["mac.local"])
        XCTAssertEqual(settings.pairedDevices[0].token, "old")
        XCTAssertFalse(settings.foldLegacyConnection(), "第二次不应再有改动")
    }

    func testExistingDeviceForTheSameEndpointIsNotOverwritten() {
        var settings = AppSettings(remoteHost: "mac.local", remotePort: 8795, remoteToken: "old")
        settings.pairedDevices.upsert(PairedDevice(name: "Studio", transport: .lan, host: "mac.local", port: 8795, token: "new"))
        XCTAssertTrue(settings.foldLegacyConnection())
        XCTAssertEqual(settings.pairedDevices.count, 1)
        XCTAssertEqual(settings.pairedDevices[0].token, "new")
        XCTAssertEqual(settings.pairedDevices[0].name, "Studio")
    }
}

private final class MemorySecrets: SecretStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failWrites = false
    func secret(for account: String) throws -> String? { values[account] }
    func setSecret(_ value: String?, for account: String) throws {
        if failWrites { throw ProviderError.transport("vault down") }
        values[account] = value
    }
}

final class PairedDeviceVaultTests: XCTestCase {
    private func device(_ token: String) -> PairedDevice {
        PairedDevice(name: "Mac", transport: .lan, host: "h", port: 1, token: token)
    }

    func testPersistedCopyHasNoTokenAndVaultHasIt() {
        let vault = MemorySecrets()
        let d = device("secret-token")
        let out = PairedDeviceVault.persistable([d], previous: [], secrets: vault)
        XCTAssertEqual(out[0].token, "")
        XCTAssertEqual(vault.values[PairedDeviceVault.account(for: d.id)], "secret-token")
        let json = String(decoding: try! JSONEncoder().encode(out), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"), "令牌不能出现在落盘的 JSON 里")
    }

    func testHydrateRestoresTokenFromVault() {
        let vault = MemorySecrets()
        let d = device("abc")
        let stored = PairedDeviceVault.persistable([d], previous: [], secrets: vault)
        let back = PairedDeviceVault.hydrate(stored, secrets: vault)
        XCTAssertEqual(back.devices[0].token, "abc")
        XCTAssertFalse(back.needsRewrite)
    }

    func testLegacyPlaintextTokenIsMigratedAndFlaggedForRewrite() {
        let vault = MemorySecrets()
        let legacy = device("old-plain")
        let back = PairedDeviceVault.hydrate([legacy], secrets: vault)
        XCTAssertEqual(back.devices[0].token, "old-plain")
        XCTAssertTrue(back.needsRewrite)
        XCTAssertEqual(vault.values[PairedDeviceVault.account(for: legacy.id)], "old-plain")
    }

    func testPlaintextLeftBesideAnExistingVaultEntryIsStillScheduledForRewrite() {
        let vault = MemorySecrets()
        let d = device("in-both")
        vault.values[PairedDeviceVault.account(for: d.id)] = "stale-older"
        let back = PairedDeviceVault.hydrate([d], secrets: vault)
        XCTAssertTrue(back.needsRewrite, "文档里残留明文令牌时必须重写")
        XCTAssertEqual(back.devices[0].token, "in-both", "文档里的明文更新，应覆盖保管库里的旧值")
        XCTAssertEqual(vault.values[PairedDeviceVault.account(for: d.id)], "in-both")
    }

    func testFailingVaultKeepsTheTokenInTheDocument() {
        let vault = MemorySecrets()
        vault.failWrites = true
        let d = device("keep-me")
        XCTAssertEqual(PairedDeviceVault.persistable([d], previous: [], secrets: vault)[0].token, "keep-me")
        XCTAssertFalse(PairedDeviceVault.hydrate([d], secrets: vault).needsRewrite, "迁移失败不能让文档丢掉令牌")
    }

    func testForgottenDeviceIsRemovedFromVault() {
        let vault = MemorySecrets()
        let a = device("a"), b = PairedDevice(name: "B", transport: .lan, host: "b", port: 2, token: "b")
        _ = PairedDeviceVault.persistable([a, b], previous: [], secrets: vault)
        _ = PairedDeviceVault.persistable([b], previous: [a, b], secrets: vault)
        XCTAssertNil(vault.values[PairedDeviceVault.account(for: a.id)] ?? nil)
        XCTAssertEqual(vault.values[PairedDeviceVault.account(for: b.id)], "b")
    }
}
