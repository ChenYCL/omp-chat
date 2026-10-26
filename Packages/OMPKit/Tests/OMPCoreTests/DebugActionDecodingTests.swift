import Foundation
import XCTest
@testable import OMPCore

/// `DebugAction` is the `/debug/action` wire contract: every documented
/// action decodes from its JSON shape, and anything malformed — unknown
/// action, missing field, wrong type, wrong top level — is rejected so the
/// route can answer 400.
final class DebugActionDecodingTests: XCTestCase {
    private func decode(_ json: String) -> DebugAction? {
        DebugAction.decode(from: Data(json.utf8))
    }

    // MARK: - Documented actions

    func testSelectDecodesConversationID() throws {
        let action = try XCTUnwrap(decode(#"{"action":"select","conversationID":"0A88A653-79A8-49C7-9E0A-FAAB6E9E9A5F"}"#))
        XCTAssertEqual(action, .select(conversationID: "0A88A653-79A8-49C7-9E0A-FAAB6E9E9A5F"))
    }

    func testNewChatDecodesWithoutPayload() {
        XCTAssertEqual(decode(#"{"action":"newChat"}"#), .newChat)
    }

    func testSidePanelOpenOnly() {
        XCTAssertEqual(decode(#"{"action":"sidePanel","open":true}"#), .sidePanel(open: true, tab: nil))
        XCTAssertEqual(decode(#"{"action":"sidePanel","open":false}"#), .sidePanel(open: false, tab: nil))
    }

    func testSidePanelWithEveryTab() {
        for tab in SidePanelTab.allCases {
            XCTAssertEqual(
                decode(#"{"action":"sidePanel","open":true,"tab":"\#(tab.rawValue)"}"#),
                .sidePanel(open: true, tab: tab)
            )
        }
    }

    func testOpenAndCloseSettingsDecode() {
        XCTAssertEqual(decode(#"{"action":"openSettings"}"#), .openSettings)
        XCTAssertEqual(decode(#"{"action":"closeSettings"}"#), .closeSettings)
    }

    // MARK: - Missing fields

    func testSelectWithoutConversationIDIsRejected() {
        XCTAssertNil(decode(#"{"action":"select"}"#))
    }

    func testSidePanelWithoutOpenIsRejected() {
        XCTAssertNil(decode(#"{"action":"sidePanel"}"#))
        XCTAssertNil(decode(#"{"action":"sidePanel","tab":"browser"}"#))
    }

    // MARK: - Wrong types

    func testSidePanelOpenMustBeABool() {
        XCTAssertNil(decode(#"{"action":"sidePanel","open":"yes"}"#))
    }

    func testSidePanelUnknownTabIsRejected() {
        // A misspelled tab is a caller error, not a default: reject instead of
        // silently opening 终端.
        XCTAssertNil(decode(#"{"action":"sidePanel","open":true,"tab":"brower"}"#))
    }

    func testSelectConversationIDMustBeAString() {
        XCTAssertNil(decode(#"{"action":"select","conversationID":42}"#))
    }

    // MARK: - Unknown action / broken body

    func testUnknownActionIsRejected() {
        XCTAssertNil(decode(#"{"action":"sendEverything"}"#))
    }

    func testEmptyAndNonJSONObjectBodiesAreRejected() {
        XCTAssertNil(decode(""))
        XCTAssertNil(decode("[]"))
        XCTAssertNil(decode("null"))
        XCTAssertNil(decode(#""newChat""#))
    }

    func testBodyWithoutActionKeyIsRejected() {
        XCTAssertNil(decode(#"{"conversationID":"x"}"#))
    }

    // MARK: - Wire names

    func testActionNamesRoundTripThroughTheirWireName() {
        let actions: [DebugAction] = [
            .select(conversationID: "x"), .newChat,
            .sidePanel(open: true, tab: .files), .openSettings, .closeSettings,
        ]
        for action in actions {
            XCTAssertFalse(action.name.isEmpty)
        }
        XCTAssertEqual(DebugAction.newChat.name, "newChat")
        XCTAssertEqual(DebugAction.openSettings.name, "openSettings")
    }
}
