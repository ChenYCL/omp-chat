import Foundation
import OMPCore
import XCTest
@testable import OMPChatUI

final class DiagnosticsCheckTests: XCTestCase {
    func testUnconfiguredProviderFails() async {
        let context = DiagnosticsContext(
            providers: [], apiKeys: [:], storeDirectory: nil,
            relayEnabled: false, relayPort: 8790, relayListening: false,
            relayToken: "", relayRoomCode: "", relayHubURL: "", relayAllowShell: false,
            transport: URLSessionTransport())
        let result = await DiagnosticsChecks.providerRoundTrip(context)
        XCTAssertEqual(result.status, .fail)
        XCTAssertFalse(result.hint.isEmpty)
    }

    func testWorkspaceCheckSkipsWithoutAFileStore() {
        let context = DiagnosticsContext(
            providers: [], apiKeys: [:], storeDirectory: nil,
            relayEnabled: false, relayPort: 8790, relayListening: false,
            relayToken: "", relayRoomCode: "", relayHubURL: "", relayAllowShell: false,
            transport: URLSessionTransport())
        XCTAssertEqual(DiagnosticsChecks.workspaceDecodes(context).status, .skip)
    }

    func testUndecodableWorkspaceFails() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ this is not json".utf8)
            .write(to: directory.appendingPathComponent("workspace.json"))
        let context = DiagnosticsContext(
            providers: [], apiKeys: [:], storeDirectory: directory,
            relayEnabled: false, relayPort: 8790, relayListening: false,
            relayToken: "", relayRoomCode: "", relayHubURL: "", relayAllowShell: false,
            transport: URLSessionTransport())
        XCTAssertEqual(DiagnosticsChecks.workspaceDecodes(context).status, .fail)
    }

    func testRelayCredentialsAreMasked() {
        let context = DiagnosticsContext(
            providers: [], apiKeys: [:], storeDirectory: nil,
            relayEnabled: true, relayPort: 8790, relayListening: false,
            relayToken: "abcdef0123456789", relayRoomCode: "", relayHubURL: "", relayAllowShell: false,
            transport: URLSessionTransport())
        let result = DiagnosticsChecks.relayCredentials(context)
        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.detail.contains("abcdef0123456789"))
    }
    func testPairedHostProbeFailureMapsToFail() async {
        var context = DiagnosticsContext(
            providers: [], apiKeys: [:], storeDirectory: nil,
            relayEnabled: false, relayPort: 8790, relayListening: false,
            relayToken: "", relayRoomCode: "", relayHubURL: "", relayAllowShell: false,
            transport: URLSessionTransport())
        context.pairedHostProbe = { false }
        let result = await DiagnosticsChecks.pairedHost(context)
        XCTAssertEqual(result.status, .fail)
        XCTAssertFalse(result.hint.isEmpty)
    }
}
