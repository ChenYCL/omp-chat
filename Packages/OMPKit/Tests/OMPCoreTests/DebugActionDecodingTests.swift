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
        XCTAssertEqual(decode(#"{"action":"openSettings"}"#), .openSettings(section: nil))
        XCTAssertEqual(decode(#"{"action":"openSettings","section":"usage"}"#), .openSettings(section: "usage"))
        XCTAssertNil(decode(#"{"action":"openSettings","section":7}"#))
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

    func testSideChatActions() {
        XCTAssertEqual(decode(#"{"action":"sideChat","text":"方案是什么"}"#), .sideChat(conversationID: nil, text: "方案是什么"))
        XCTAssertEqual(
            decode(#"{"action":"sideChat","conversationID":"abc","text":""}"#),
            .sideChat(conversationID: "abc", text: ""),
            "空问题由宿主拒绝并说明原因，不是格式错误"
        )
        XCTAssertNil(decode(#"{"action":"sideChat"}"#), "text 必填")
        XCTAssertNil(decode(#"{"action":"sideChat","conversationID":3,"text":"x"}"#))
        XCTAssertEqual(decode(#"{"action":"clearSideChat"}"#), .clearSideChat(conversationID: nil))
        XCTAssertEqual(decode(#"{"action":"stopSideChat"}"#), .stopSideChat)
    }

    func testBrowserTabActions() {
        XCTAssertEqual(decode(#"{"action":"browserOpenTab"}"#), .browserOpenTab(url: nil, rightOf: nil), "不带地址就开首页、加到末尾")
        XCTAssertEqual(
            decode(#"{"action":"browserOpenTab","url":"http://127.0.0.1:8795","rightOf":"t1"}"#),
            .browserOpenTab(url: "http://127.0.0.1:8795", rightOf: "t1")
        )
        XCTAssertNil(decode(#"{"action":"browserOpenTab","url":5}"#))
        XCTAssertEqual(decode(#"{"action":"browserRenameTab","tabID":"t1","title":""}"#), .browserRenameTab(tabID: "t1", title: ""))
        XCTAssertNil(decode(#"{"action":"browserRenameTab","tabID":"t1"}"#), "title 必填，空串才是清除")
        XCTAssertEqual(
            decode(#"{"action":"browserNavigate","tabID":"t1","url":"https://example.com"}"#),
            .browserNavigate(tabID: "t1", url: "https://example.com")
        )
        XCTAssertNil(decode(#"{"action":"browserNavigate","tabID":"t1","url":"example dot com"}"#),
                     "地址栏的搜索/补 https 规则只在界面里，这里只收完整地址")
        for name in ["browserCloseTab", "browserDuplicateTab", "browserSelectTab"] {
            XCTAssertNil(decode(#"{"action":"\#(name)"}"#), "\(name) 要 tabID")
        }
    }

    func testGitOperations() {
        XCTAssertEqual(
            decode(#"{"action":"git","op":"stage","paths":["说明 文档.md","a.txt"]}"#),
            .git(conversationID: nil, operation: .stage(["说明 文档.md", "a.txt"]))
        )
        XCTAssertEqual(decode(#"{"action":"git","op":"unstageAll","conversationID":"abc"}"#),
                       .git(conversationID: "abc", operation: .unstageAll))
        XCTAssertEqual(decode(#"{"action":"git","op":"commit","message":""}"#),
                       .git(conversationID: nil, operation: .commit("")), "空说明交给宿主拒绝并说明原因")
        XCTAssertEqual(decode(#"{"action":"git","op":"push"}"#), .git(conversationID: nil, operation: .push))
        XCTAssertNil(decode(#"{"action":"git","op":"stage"}"#), "暂存要给路径")
        XCTAssertNil(decode(#"{"action":"git","op":"stage","paths":[]}"#), "空列表等于没给")
        XCTAssertNil(decode(#"{"action":"git","op":"stage","paths":["a",3]}"#), "混进非字符串整条拒绝")
        XCTAssertNil(decode(#"{"action":"git","op":"discard"}"#))
        XCTAssertNil(decode(#"{"action":"git","op":"commit"}"#))
        XCTAssertNil(decode(#"{"action":"git","op":"reset"}"#), "不认识的操作")
        XCTAssertNil(decode(#"{"action":"git"}"#))
    }

    func testMCPActions() {
        XCTAssertEqual(
            decode(#"{"action":"mcpInstall","entryID":"filesystem","values":{"directories":["/tmp/a","/tmp/b"]}}"#),
            .mcpInstall(entryID: "filesystem", values: ["directories": ["/tmp/a", "/tmp/b"]])
        )
        XCTAssertEqual(decode(#"{"action":"mcpInstall","entryID":"git"}"#), .mcpInstall(entryID: "git", values: [:]),
                       "没有必填项的条目可以不带 values")
        XCTAssertNil(decode(#"{"action":"mcpInstall"}"#))
        XCTAssertNil(decode(#"{"action":"mcpInstall","entryID":"fs","values":{"directories":"/tmp/a"}}"#),
                     "答案必须是字符串数组，单个字符串不能被当成空答案")
        XCTAssertNil(decode(#"{"action":"mcpInstall","entryID":"fs","values":{"directories":["/tmp",1]}}"#))
        XCTAssertNil(decode(#"{"action":"mcpInstall","entryID":"fs","values":["/tmp"]}"#))
        XCTAssertEqual(decode(#"{"action":"mcpRemove","serverID":"filesystem"}"#), .mcpRemove(serverID: "filesystem"))
        XCTAssertNil(decode(#"{"action":"mcpRemove"}"#))
    }

    func testAgentActions() {
        XCTAssertEqual(decode(#"{"action":"send","text":"跑一下测试"}"#), .send(conversationID: nil, text: "跑一下测试"))
        XCTAssertNil(decode(#"{"action":"send"}"#), "text 必填")
        XCTAssertEqual(decode(#"{"action":"stop"}"#), .stop)
        XCTAssertEqual(
            decode(#"{"action":"approve","approvalID":"a1","decision":"allowAlways"}"#),
            .approve(approvalID: "a1", decision: .allowAlways)
        )
        XCTAssertNil(decode(#"{"action":"approve","approvalID":"a1","decision":"yes"}"#), "未知决定不能当成允许")
        XCTAssertNil(decode(#"{"action":"approve","decision":"deny"}"#))
        XCTAssertEqual(decode(#"{"action":"setPermissionMode","mode":"readOnly"}"#),
                       .setPermissionMode(conversationID: nil, mode: .readOnly))
        XCTAssertEqual(decode(#"{"action":"setPermissionMode","mode":null}"#),
                       .setPermissionMode(conversationID: nil, mode: nil), "null 表示跟随默认")
        XCTAssertNil(decode(#"{"action":"setPermissionMode","mode":"yolo"}"#), "未知模式不能悄悄退回默认")
        XCTAssertEqual(decode(#"{"action":"setToolsEnabled","enabled":false,"conversationID":"c"}"#),
                       .setToolsEnabled(conversationID: "c", enabled: false))
        XCTAssertEqual(decode(#"{"action":"setToolsEnabled"}"#), .setToolsEnabled(conversationID: nil, enabled: nil))
        XCTAssertNil(decode(#"{"action":"setToolsEnabled","enabled":"true"}"#), "字符串不是布尔值")
    }

    func testOpenLinkAndDeleteNeedTheirField() {
        XCTAssertEqual(decode(#"{"action":"openLink","url":"ompchat://thread/x"}"#), .openLink(url: "ompchat://thread/x"))
        XCTAssertNil(decode(#"{"action":"openLink"}"#))
        XCTAssertEqual(decode(#"{"action":"delete","conversationID":"abc"}"#), .delete(conversationID: "abc"))
        XCTAssertNil(decode(#"{"action":"delete"}"#))
        XCTAssertEqual(decode(#"{"action":"dismissError"}"#), .dismissError)
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
            #"{"action":"dismissError"}"#,
            #"{"action":"sideChat","text":"x"}"#,
            #"{"action":"clearSideChat"}"#,
            #"{"action":"stopSideChat"}"#,
            #"{"action":"browserOpenTab"}"#,
            #"{"action":"browserCloseTab","tabID":"x"}"#,
            #"{"action":"browserDuplicateTab","tabID":"x"}"#,
            #"{"action":"browserRenameTab","tabID":"x","title":"y"}"#,
            #"{"action":"browserSelectTab","tabID":"x"}"#,
            #"{"action":"browserNavigate","tabID":"x","url":"https://x"}"#,
            #"{"action":"git","op":"push"}"#,
            #"{"action":"send","text":"x"}"#,
            #"{"action":"stop"}"#,
            #"{"action":"approve","approvalID":"x","decision":"deny"}"#,
            #"{"action":"setPermissionMode","mode":"ask"}"#,
            #"{"action":"setToolsEnabled","enabled":true}"#,
            #"{"action":"mcpInstall","entryID":"x"}"#,
            #"{"action":"mcpRemove","serverID":"x"}"#,
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
