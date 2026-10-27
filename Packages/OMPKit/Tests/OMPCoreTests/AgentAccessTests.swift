import XCTest
@testable import OMPCore

/// The composer menu checks `current` and stores `stored`; if they disagree,
/// a pick does not show, which is the bug this type replaced.
final class AgentAccessTests: XCTestCase {
    private func current(_ tools: Bool?, _ mode: PermissionMode?, directory: Bool = false,
                         defaultMode: PermissionMode = .ask) -> AgentAccess {
        AgentAccess.current(toolsEnabled: tools, permissionMode: mode, hasWorkingDirectory: directory, defaultMode: defaultMode)
    }

    func testEveryPickIsWhatTheMenuThenChecks() {
        for choice in AgentAccess.allChoices {
            for directory in [false, true] {
                let stored = choice.stored
                XCTAssertEqual(current(stored.toolsEnabled, stored.permissionMode, directory: directory), choice,
                               "选了「\(choice.title)」，菜单就该勾它（有工作目录：\(directory)）")
            }
        }
    }

    func testAModeWithoutToolsFromOlderVersionsShowsWhatTheThreadGets() {
        // The reported state: 完全访问 saved while tools followed the directory.
        XCTAssertEqual(current(nil, .full, directory: false), .chatOnly, "没有工作目录就没有工具，勾仅聊天")
        XCTAssertEqual(current(nil, .full, directory: true), .tools(.full))
        XCTAssertEqual(current(false, .full), .chatOnly, "明确关了工具就是仅聊天")
        XCTAssertEqual(current(true, nil, defaultMode: .auto), .tools(.auto), "开了工具没选模式，用默认模式")
    }

    func testChatOnlyLeavesNoHiddenMode() {
        XCTAssertEqual(AgentAccess.chatOnly.stored.permissionMode, nil)
        XCTAssertEqual(AgentAccess.chatOnly.stored.toolsEnabled, false)
    }

    func testDefaultResolvesByWorkingDirectory() {
        XCTAssertEqual(AgentAccess.followDefault.resolved(hasWorkingDirectory: false, defaultMode: .full), .chatOnly)
        XCTAssertEqual(AgentAccess.followDefault.resolved(hasWorkingDirectory: true, defaultMode: .full), .tools(.full))
        XCTAssertEqual(AgentAccess.tools(.readOnly).resolved(hasWorkingDirectory: false, defaultMode: .full), .tools(.readOnly),
                       "明确的选择不受默认值影响")
    }

    func testWireValuesRoundTripAndRejectOthers() {
        for choice in AgentAccess.allChoices {
            XCTAssertEqual(AgentAccess(wireValue: choice.wireValue), choice)
        }
        XCTAssertEqual(Set(AgentAccess.allChoices.map(\.wireValue)).count, AgentAccess.allChoices.count, "名字不能重复")
        XCTAssertNil(AgentAccess(wireValue: "agent"))
        XCTAssertNil(AgentAccess(wireValue: ""))
    }
}
