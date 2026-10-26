import XCTest
@testable import OMPCore

final class SidebarOrganizationTests: XCTestCase {
    private func conversation(
        title: String,
        providerID: UUID? = nil,
        updatedAt: Date,
        workingDirectory: String? = nil,
        isArchived: Bool = false,
        isLocked: Bool = false,
        isTemporary: Bool = false
    ) -> Conversation {
        var conversation = Conversation(title: title, providerID: providerID, updatedAt: updatedAt)
        conversation.workingDirectory = workingDirectory
        conversation.isArchived = isArchived
        conversation.isLocked = isLocked
        conversation.isTemporary = isTemporary
        return conversation
    }

    func testFilterSplitsChatAndWork() {
        let chat = conversation(title: "闲聊", updatedAt: Date())
        let work = conversation(title: "改仓库", updatedAt: Date(), workingDirectory: "/repo")

        XCTAssertEqual(SidebarOrganization.filter([chat, work], by: .all).map(\.title), ["闲聊", "改仓库"])
        XCTAssertEqual(SidebarOrganization.filter([chat, work], by: .chat).map(\.title), ["闲聊"],
                       "没有工作目录的才算聊天")
        XCTAssertEqual(SidebarOrganization.filter([chat, work], by: .work).map(\.title), ["改仓库"],
                       "绑了工作目录的才算工作")
    }

    func testFilterTreatsEmptyDirectoryAsWork() {
        let bound = conversation(title: "空路径", updatedAt: Date(), workingDirectory: "")
        XCTAssertEqual(SidebarOrganization.filter([bound], by: .work).map(\.title), ["空路径"],
                       "只要绑了目录就算工作，哪怕路径是空串")
        XCTAssertTrue(SidebarOrganization.filter([bound], by: .chat).isEmpty)
    }

    func testConnectionGroupsUnknownProviderTogether() {
        let known = UUID()
        let gone = UUID()
        let provider = ProviderProfile(id: known, name: "DeepSeek", kind: .openAICompatible,
                                       baseURL: URL(string: "https://example.test")!)
        let newer = conversation(title: "新的", providerID: nil, updatedAt: Date(timeIntervalSince1970: 300))
        let named = conversation(title: "有名", providerID: known, updatedAt: Date(timeIntervalSince1970: 200))
        let missing = conversation(title: "失踪", providerID: gone, updatedAt: Date(timeIntervalSince1970: 100))

        let groups = SidebarOrganization.connectionGroups([named, newer, missing], providers: [provider])

        XCTAssertEqual(groups.map(\.name), ["未知连接", "DeepSeek"], "按组内最近活动倒序")
        XCTAssertEqual(groups[0].conversations.map(\.title), ["新的", "失踪"],
                       "没填和填了已删除供应商的归到同一组，且组内保持输入顺序")
        XCTAssertNil(groups[0].providerID)
        XCTAssertEqual(groups[1].providerID, known)
    }

    func testConnectionGroupsOrderByMostRecentActivity() {
        let a = UUID()
        let b = UUID()
        let providers = [
            ProviderProfile(id: a, name: "甲", kind: .openAICompatible, baseURL: URL(string: "https://a.test")!),
            ProviderProfile(id: b, name: "乙", kind: .openAICompatible, baseURL: URL(string: "https://b.test")!),
        ]
        let oldA = conversation(title: "甲旧", providerID: a, updatedAt: Date(timeIntervalSince1970: 10))
        let newB = conversation(title: "乙新", providerID: b, updatedAt: Date(timeIntervalSince1970: 50))
        let newA = conversation(title: "甲新", providerID: a, updatedAt: Date(timeIntervalSince1970: 40))

        let groups = SidebarOrganization.connectionGroups([oldA, newB, newA], providers: providers)

        XCTAssertEqual(groups.map(\.name), ["乙", "甲"])
        XCTAssertEqual(groups[1].conversations.map(\.title), ["甲旧", "甲新"], "组内顺序跟输入一致，不重排")
    }

    func testExcludedConversationsStayOutWhenTheSidebarAlreadyDroppedThem() {
        // sortedConversations drops archived, locked and temporary before the
        // sidebar asks; the rule must not pull any of them back in.
        let visible = conversation(title: "在", updatedAt: Date(timeIntervalSince1970: 2))
        let archived = conversation(title: "归档", updatedAt: Date(timeIntervalSince1970: 3), isArchived: true)
        let locked = conversation(title: "锁定", updatedAt: Date(timeIntervalSince1970: 4), isLocked: true)
        let temporary = conversation(title: "临时", updatedAt: Date(timeIntervalSince1970: 5), isTemporary: true)
        let sidebarInput = [visible, archived, locked, temporary]
            .filter { !$0.isArchived && !$0.isLocked && !$0.isTemporary }

        let shown = SidebarOrganization.filter(sidebarInput, by: .all)
        XCTAssertEqual(shown.map(\.title), ["在"])
        XCTAssertEqual(SidebarOrganization.connectionGroups(shown, providers: []).map(\.conversations.count), [1])
    }

    func testStoredValuesFallBackToDefaults() {
        XCTAssertEqual(SidebarGrouping(stored: "connection"), .connection)
        XCTAssertEqual(SidebarGrouping(stored: "nonsense"), .project)
        XCTAssertEqual(SidebarFilter(stored: "work"), .work)
        XCTAssertEqual(SidebarFilter(stored: ""), .all)
    }
}
