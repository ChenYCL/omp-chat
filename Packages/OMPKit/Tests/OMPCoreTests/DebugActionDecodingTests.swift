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

    // MARK: - Composer, sidebar and thread actions

    func testSetDraftKeepsTheTextVerbatim() {
        XCTAssertEqual(decode(#"{"action":"setDraft","text":"第一行\n第二行"}"#), .setDraft(text: "第一行\n第二行"))
        XCTAssertEqual(decode(#"{"action":"setDraft","text":""}"#), .setDraft(text: ""), "空草稿是合法的")
        XCTAssertNil(decode(#"{"action":"setDraft"}"#))
    }

    func testFormatAcceptsEveryStyleAndRejectsOthers() {
        for style in DebugFormatStyle.allCases {
            XCTAssertEqual(decode(#"{"action":"format","style":"\#(style.rawValue)"}"#), .format(style))
        }
        XCTAssertNil(decode(#"{"action":"format","style":"heading4"}"#))
        XCTAssertNil(decode(#"{"action":"format"}"#))
    }

    func testSetGoalTargetsSelectedOrNamedConversation() {
        XCTAssertEqual(decode(#"{"action":"setGoal","goal":"发布"}"#), .setGoal(conversationID: nil, goal: "发布"))
        XCTAssertEqual(
            decode(#"{"action":"setGoal","conversationID":"abc","goal":""}"#),
            .setGoal(conversationID: "abc", goal: ""),
            "空字符串表示清除目标"
        )
        XCTAssertNil(decode(#"{"action":"setGoal"}"#), "goal 必填")
        XCTAssertNil(decode(#"{"action":"setGoal","goal":null}"#), "null 不能当清除")
        XCTAssertNil(decode(#"{"action":"setGoal","conversationID":7,"goal":"x"}"#))
    }

    func testSidebarNeedsAKnownGroupingOrFilter() {
        XCTAssertEqual(decode(#"{"action":"sidebar","grouping":"connection"}"#), .sidebar(grouping: .connection, filter: nil))
        XCTAssertEqual(decode(#"{"action":"sidebar","filter":"work"}"#), .sidebar(grouping: nil, filter: .work))
        XCTAssertEqual(
            decode(#"{"action":"sidebar","grouping":"project","filter":"all"}"#),
            .sidebar(grouping: .project, filter: .all)
        )
        XCTAssertNil(decode(#"{"action":"sidebar"}"#), "什么都不改的调用是调用方的错")
        XCTAssertNil(decode(#"{"action":"sidebar","grouping":"date"}"#), "未知分组不能被悄悄忽略")
        XCTAssertNil(decode(#"{"action":"sidebar","grouping":"connection","filter":"pinned"}"#), "一个值不认识就整条拒绝")
    }

    func testUnreadActions() {
        XCTAssertEqual(decode(#"{"action":"markAllRead"}"#), .markAllRead)
        XCTAssertEqual(
            decode(#"{"action":"setUnread","conversationID":"abc","unread":true}"#),
            .setUnread(conversationID: "abc", unread: true)
        )
        XCTAssertNil(decode(#"{"action":"setUnread","conversationID":"abc"}"#))
        XCTAssertNil(decode(#"{"action":"setUnread","unread":false}"#))
    }

    func testContinueInModes() {
        XCTAssertEqual(decode(#"{"action":"continueIn","mode":"local"}"#), .continueIn(conversationID: nil, target: .local))
        XCTAssertEqual(decode(#"{"action":"continueIn","mode":"worktree"}"#), .continueIn(conversationID: nil, target: .worktree))
        XCTAssertEqual(
            decode(#"{"action":"continueIn","conversationID":"abc","mode":"folder","path":"/tmp/x"}"#),
            .continueIn(conversationID: "abc", target: .folder("/tmp/x"))
        )
        XCTAssertNil(decode(#"{"action":"continueIn","mode":"folder"}"#), "选择文件夹必须带路径")
        XCTAssertNil(decode(#"{"action":"continueIn","mode":"folder","path":"  "}"#), "空白路径等于没有")
        XCTAssertNil(decode(#"{"action":"continueIn","mode":"cloud"}"#))
    }

    func testForkModesUseTheForkModeRawValues() {
        for mode in ForkMode.allCases {
            XCTAssertEqual(decode(#"{"action":"fork","mode":"\#(mode.rawValue)"}"#), .fork(conversationID: nil, mode: mode))
        }
        XCTAssertNil(decode(#"{"action":"fork","mode":"remote"}"#))
        XCTAssertNil(decode(#"{"action":"fork"}"#))
    }

    func testOpenLinkAndDeleteNeedTheirField() {
        XCTAssertEqual(decode(#"{"action":"openLink","url":"ompchat://thread/x"}"#), .openLink(url: "ompchat://thread/x"))
        XCTAssertNil(decode(#"{"action":"openLink"}"#))
        XCTAssertEqual(decode(#"{"action":"delete","conversationID":"abc"}"#), .delete(conversationID: "abc"))
        XCTAssertNil(decode(#"{"action":"delete"}"#))
    }

    // MARK: - Wire names

    /// `name` is what ompshot prints and what the docs list; it must be the
    /// exact `action` string the decoder accepted.
    func testDecodedActionNameIsTheWireName() throws {
        let bodies = [
            #"{"action":"select","conversationID":"x"}"#,
            #"{"action":"newChat"}"#,
            #"{"action":"sidePanel","open":true}"#,
            #"{"action":"openSettings"}"#,
            #"{"action":"closeSettings"}"#,
            #"{"action":"setDraft","text":"x"}"#,
            #"{"action":"format","style":"bold"}"#,
            #"{"action":"setGoal","goal":"x"}"#,
            #"{"action":"sidebar","filter":"chat"}"#,
            #"{"action":"markAllRead"}"#,
            #"{"action":"setUnread","conversationID":"x","unread":false}"#,
            #"{"action":"continueIn","mode":"local"}"#,
            #"{"action":"fork","mode":"local"}"#,
            #"{"action":"openLink","url":"x"}"#,
            #"{"action":"delete","conversationID":"x"}"#,
        ]
        for body in bodies {
            let action = try XCTUnwrap(decode(body), body)
            let sent = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["action"] as? String
            )
            XCTAssertEqual(action.name, sent, body)
        }
    }
}
