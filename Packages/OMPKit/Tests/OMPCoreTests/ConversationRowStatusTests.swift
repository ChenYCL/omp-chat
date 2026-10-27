import XCTest
@testable import OMPCore

/// Row tags are what tells a thread waiting on the user apart from any other
/// row, so the rules — which tag wins, what clears one — are checked here.
final class ConversationRowStatusTests: XCTestCase {
    private func message(_ role: MessageRole, _ text: String, _ status: MessageStatus = .complete,
                         error: String? = nil) -> ChatMessage {
        var message = ChatMessage(role: role, parts: [.text(text)], status: status)
        message.errorText = error
        return message
    }

    private func conversation(_ messages: [ChatMessage]) -> Conversation {
        var conversation = Conversation(title: "t")
        conversation.messages = messages
        return conversation
    }

    private func failedThread() -> Conversation {
        conversation([message(.user, "查一下"), message(.assistant, "", .failed, error: "网络连接已中断")])
    }

    func testAPlainFinishedThreadHasNoTag() {
        let status = ConversationRowStatus(conversation([message(.user, "问"), message(.assistant, "答")]), facts: .init())
        XCTAssertEqual(status, .none)
        XCTAssertNil(status.primary)
    }

    func testAFailedLastReplyIsASystemError() {
        let status = ConversationRowStatus(failedThread(), facts: .init())
        XCTAssertEqual(status.tags, [.systemError])
        XCTAssertTrue(status.isBlocking)
    }

    func testANewerSuccessfulReplyClearsTheError() {
        var thread = failedThread()
        thread.messages += [message(.user, "重试"), message(.assistant, "好了")]
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [], "后来的回复成功，错误不再挂着")
    }

    func testAUserMessageAfterTheFailureIsNotAnErrorAnyMore() {
        var thread = failedThread()
        thread.messages.append(message(.user, "再试一次"))
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [])
    }

    func testHeldFollowUpsNeedInput() {
        var thread = conversation([message(.user, "改一下"), message(.assistant, "改了一半")])
        thread.queuedMessages = [QueuedMessage(text: "顺便跑测试", isHeld: true)]
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [.needsInput])

        thread.queuedMessages = [QueuedMessage(text: "顺便跑测试", isHeld: false)]
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [], "还会自动发出的排队消息不用用户处理")
    }

    func testAnUnansweredFollowUpNeedsInputUntilANewerMessage() {
        var thread = conversation([
            message(.user, "先查"), message(.assistant, "查到了"),
            message(.user, "再改", error: ConversationRowStatus.unansweredFollowUpNote),
        ])
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [.needsInput])

        thread.messages.append(message(.user, "换个问题"))
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [], "只看最新的用户消息")
    }

    func testAPendingApprovalOutranksEverythingAndShowsOnlyOneBlockingTag() {
        var thread = failedThread()
        thread.queuedMessages = [QueuedMessage(text: "追问", isHeld: true)]
        thread.scheduledTaskID = UUID()
        let attached = UUID()
        let status = ConversationRowStatus(thread, facts: .init(
            hasPendingApproval: true, originTaskIsLive: true, attachedTaskID: attached
        ))
        XCTAssertEqual(status.primary, .awaitingApproval)
        XCTAssertEqual(Array(status.secondary), [.automation, .attachedAutomation],
                       "需要你处理和系统错误被批准挡住；定时任务来源照常显示")
    }

    func testNeedsInputOutranksASystemError() {
        var thread = failedThread()
        thread.queuedMessages = [QueuedMessage(text: "追问", isHeld: true)]
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init()).tags, [.needsInput])
    }

    func testAWorkingThreadDoesNotWaitOnTheUserButCanWaitForApproval() {
        var thread = failedThread()
        thread.queuedMessages = [QueuedMessage(text: "追问", isHeld: true)]
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init(isBusy: true)).tags, [],
                       "回复或压缩进行中不显示需要你处理 / 系统错误")
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init(hasPendingApproval: true, isBusy: true)).tags,
                       [.awaitingApproval])
    }

    func testTaskTagsAloneMakeTheFirstOnePrimary() {
        var thread = conversation([message(.user, "日报"), message(.assistant, "三次提交")])
        thread.scheduledTaskID = UUID()
        let status = ConversationRowStatus(thread, facts: .init(originTaskIsLive: true, attachedTaskID: UUID()))
        XCTAssertEqual(status.primary, .automation)
        XCTAssertEqual(Array(status.secondary), [.attachedAutomation])
        XCTAssertFalse(status.isBlocking)
    }

    func testTheLinkedTaskPrefersALiveOriginAndADeletedOneKeepsOnlyTheTag() {
        let origin = UUID()
        let attached = UUID()
        var thread = conversation([message(.user, "日报")])
        thread.scheduledTaskID = origin

        XCTAssertEqual(ConversationRowStatus(thread, facts: .init(originTaskIsLive: true, attachedTaskID: attached)).taskID, origin)
        let deleted = ConversationRowStatus(thread, facts: .init(originTaskIsLive: false))
        XCTAssertEqual(deleted.tags, [.automation], "删掉任务后来源标签还在，它是历史")
        XCTAssertNil(deleted.taskID, "但没有任务可打开")
        XCTAssertEqual(ConversationRowStatus(thread, facts: .init(attachedTaskID: attached)).taskID, attached)
    }

    // MARK: Persistence

    func testScheduledTaskOriginRoundTripsAndOldDocumentsHaveNone() throws {
        var thread = Conversation(title: "日报 · 09:00")
        thread.scheduledTaskID = UUID()
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(decoded.scheduledTaskID, thread.scheduledTaskID)

        let old = #"{"id":"\#(UUID().uuidString)","title":"旧对话"}"#
        XCTAssertNil(try JSONDecoder().decode(Conversation.self, from: Data(old.utf8)).scheduledTaskID)
    }

    // MARK: Relay

    func testRelayStatusIsOmittedWhenNoneAndDecodesWhenPresent() throws {
        let plain = RelayConversation(id: "C1", title: "对话", updatedAt: Date(), project: nil, isStreaming: false, messages: [])
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(plainJSON["status"], "没有标签不编码，老手机的快照不变")
        XCTAssertNil(try JSONDecoder().decode(RelayConversation.self, from: JSONEncoder().encode(plain)).rowTag)

        let failed = RelayConversation(id: "C1", title: "对话", updatedAt: Date(), project: nil, isStreaming: false,
                                       messages: [], status: ConversationRowTag.systemError.rawValue)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(failed)) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "systemError")
        XCTAssertEqual(try JSONDecoder().decode(RelayConversation.self, from: JSONEncoder().encode(failed)).rowTag, .systemError)
    }

    func testAPhoneIgnoresAStatusItDoesNotKnow() throws {
        let raw = #"{"id":"C1","title":"对话","isStreaming":false,"messages":[],"status":"somethingNewer"}"#
        let decoded = try JSONDecoder().decode(RelayConversation.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.status, "somethingNewer")
        XCTAssertNil(decoded.rowTag)
        XCTAssertEqual(ConversationRowTag(rawValue: "attachedHeartbeatAutomation"), .attachedAutomation, "官方键名")
    }

    // MARK: 待处理

    func testThePriorityGroupTakesApprovalAndNeedsInputRows() {
        let approval = conversation([message(.user, "改"), message(.assistant, "")])
        var held = conversation([message(.user, "改"), message(.assistant, "好")])
        held.queuedMessages = [QueuedMessage(text: "追问", isHeld: true)]
        let plain = conversation([message(.user, "问"), message(.assistant, "答")])

        let ids = ConversationPriority.ids(in: [approval, held, plain], streamingID: nil, awaitingApprovalIDs: [approval.id])
        XCTAssertEqual(ids, [approval.id, held.id])
    }

    func testArchivedAndLockedRowsStayOutEvenWhenWaiting() {
        var archived = conversation([message(.user, "改"), message(.assistant, "好")])
        archived.isArchived = true
        var locked = conversation([message(.user, "改"), message(.assistant, "好")])
        locked.isLocked = true
        locked.queuedMessages = [QueuedMessage(text: "追问", isHeld: true)]
        XCTAssertTrue(ConversationPriority.ids(in: [archived, locked], streamingID: nil,
                                               awaitingApprovalIDs: [archived.id, locked.id]).isEmpty)
    }
}
