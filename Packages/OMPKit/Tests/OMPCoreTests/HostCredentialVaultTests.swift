import XCTest
@testable import OMPCore

final class HostCredentialVaultTests: XCTestCase {
    private final class Secrets: SecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        var failWrites = false
        func secret(for account: String) throws -> String? { values[account] }
        func setSecret(_ value: String?, for account: String) throws {
            if failWrites { throw ProviderError.transport("vault down") }
            values[account] = value
        }
    }

    func testPersistedDocumentHasNoCredentialsAndHydrateRestoresThem() throws {
        let vault = Secrets()
        let settings = AppSettings(relayToken: "tok-123", relayHubURL: "https://hub", relayRoomCode: "ROOM42")
        let persisted = HostCredentialVault.persistable(settings, secrets: vault)
        XCTAssertEqual(persisted.relayToken, "")
        XCTAssertEqual(persisted.relayRoomCode, "")
        XCTAssertEqual(persisted.relayHubURL, "https://hub", "中继地址不是凭据，照常落盘")
        let json = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(json.contains("tok-123") || json.contains("ROOM42"), "凭据不能出现在落盘的 JSON 里")

        let back = HostCredentialVault.hydrate(persisted, secrets: vault)
        XCTAssertEqual(back.settings.relayToken, "tok-123")
        XCTAssertEqual(back.settings.relayRoomCode, "ROOM42")
        XCTAssertFalse(back.needsRewrite)
    }

    func testPlaintextInTheDocumentWinsAndIsScheduledForRewrite() {
        let vault = Secrets()
        vault.values[HostCredentialVault.tokenAccount] = "stale"
        let back = HostCredentialVault.hydrate(AppSettings(relayToken: "fresh"), secrets: vault)
        XCTAssertEqual(back.settings.relayToken, "fresh")
        XCTAssertEqual(vault.values[HostCredentialVault.tokenAccount], "fresh")
        XCTAssertTrue(back.needsRewrite)
    }

    func testFailingVaultKeepsCredentialsInTheDocument() {
        let vault = Secrets()
        vault.failWrites = true
        let settings = AppSettings(relayToken: "keep", relayRoomCode: "ROOM42")
        let persisted = HostCredentialVault.persistable(settings, secrets: vault)
        XCTAssertEqual(persisted.relayToken, "keep")
        XCTAssertEqual(persisted.relayRoomCode, "ROOM42")
        XCTAssertFalse(HostCredentialVault.hydrate(settings, secrets: vault).needsRewrite, "迁移失败不能让文档丢掉凭据")
    }

    func testClearedRoomCodeRemovesItsVaultEntry() {
        let vault = Secrets()
        _ = HostCredentialVault.persistable(AppSettings(relayRoomCode: "ROOM42"), secrets: vault)
        _ = HostCredentialVault.persistable(AppSettings(), secrets: vault)
        XCTAssertNil(vault.values[HostCredentialVault.roomAccount] ?? nil)
    }
}
