import XCTest
@testable import OMPCore

/// Where a thread may be cut, what a compacted thread sends, and the
/// summarisation request.
final class ContextCompactionTests: XCTestCase {
    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, parts: [.text(text)])
    }

    private func answer(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, parts: [.text(text)])
    }

    /// An assistant turn that called `id` and holds its result, as the agent loop stores it.
    private func toolTurn(_ id: String, output: String = "README.md") -> ChatMessage {
        ChatMessage(role: .assistant, parts: [
            .toolCall(ToolCall(id: id, name: "list_dir", argumentsJSON: #"{"path":"."}"#)),
            .toolResult(ToolResult(callID: id, name: "list_dir", outputText: output)),
        ])
    }

    private func threeTurns() -> [ChatMessage] {
        [user("一"), answer("答一"), user("二"), answer("答二"), user("三"), answer("答三")]
    }

    // MARK: Boundary

    func testBoundaryKeepsTheNewestTurnsAndCutsAtAUserMessage() {
        let messages = threeTurns()
        XCTAssertEqual(ContextCompaction.boundary(in: messages, after: nil), 2, "保留最近两轮，从第二条用户消息切开")
        XCTAssertEqual(ContextCompaction.boundary(in: messages, after: nil, keepingTurns: 1), 4)
        XCTAssertNil(ContextCompaction.boundary(in: Array(messages.prefix(4)), after: nil), "只有两轮时没有更早的内容可压")
        XCTAssertNil(ContextCompaction.boundary(in: [], after: nil))
    }

    func testBoundaryNeverLeavesAKeptToolResultWithoutItsCall() {
        // A transcript where a result rides in a separate tool message after
        // the next user message (an imported or edited thread).
        let call = ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "c1", name: "list_dir", argumentsJSON: "{}"))])
        let late = ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "c1", name: "list_dir", outputText: "x"))])
        let messages = [user("一"), answer("答一"), user("二"), call, user("三"), late, answer("答三"), user("四"), answer("答四")]
        // Keeping two turns would cut at 「三」 and orphan c1's result; the cut moves to 「二」.
        let cut = ContextCompaction.boundary(in: messages, after: nil)
        XCTAssertEqual(cut, 2)
        XCTAssertFalse(ContextCompaction.orphansToolResult(messages, at: try XCTUnwrap(cut)))
        XCTAssertTrue(ContextCompaction.orphansToolResult(messages, at: 4))
    }

    func testProvidersThatReuseCallIDsStillCompact() {
        // Some gateways number calls per turn, so every turn has a `call_0`.
        let messages = [user("一"), toolTurn("call_0"), user("二"), toolTurn("call_0"), user("三"), toolTurn("call_0")]
        XCTAssertEqual(ContextCompaction.boundary(in: messages, after: nil), 2)
    }

    func testANewerCompactionOnlyCutsAfterWhatTheOlderCovers() {
        let messages = threeTurns() + [user("四"), answer("答四")]
        let older = ConversationCompaction(summary: "旧摘要", coveredThroughID: messages[1].id)
        XCTAssertEqual(ContextCompaction.boundary(in: messages, after: older), 4, "旧摘要已覆盖第一轮，新的从第三轮切")
        let covering = ConversationCompaction(summary: "旧摘要", coveredThroughID: messages[3].id)
        XCTAssertNil(ContextCompaction.boundary(in: messages, after: covering), "旧摘要之后只剩最近两轮，没有可压的")
    }

    // MARK: Requests

    func testACompactedRequestSendsTheSummaryThenOnlyTheLaterMessages() {
        let messages = threeTurns()
        let compaction = ConversationCompaction(summary: "用户问了一，助手答了一。", coveredThroughID: messages[1].id)
        let sent = ContextCompaction.requestMessages(messages, compaction: compaction)
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent[0].role, .user)
        XCTAssertEqual(sent[0].concatenatedText, "以下是此前对话的摘要：\n\n用户问了一，助手答了一。")
        XCTAssertEqual(Array(sent.dropFirst()), Array(messages.dropFirst(2)))
    }

    func testACompactionWhoseMessageIsGoneNoLongerApplies() {
        let messages = threeTurns()
        let compaction = ConversationCompaction(summary: "摘要", coveredThroughID: UUID())
        XCTAssertEqual(ContextCompaction.requestMessages(messages, compaction: compaction), messages, "被删或被编辑截掉的边界不再生效，整段照发")
        XCTAssertEqual(ContextCompaction.boundary(in: messages, after: compaction), 2, "失效的摘要不挡新的压缩")
    }

    func testOpenAIWireShapeOfACompactedThread() throws {
        let messages = threeTurns()
        let compaction = ConversationCompaction(summary: "早先的摘要", coveredThroughID: messages[1].id)
        let request = GenerationRequest(
            modelID: "m1",
            messages: ContextCompaction.requestMessages(messages, compaction: compaction),
            systemPrompt: "系统提示"
        )
        let json = try RequestBuilderTests.jsonObject(from: OpenAIRequestBuilder.build(request))
        let wire = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["system", "user", "user", "assistant", "user", "assistant"])
        XCTAssertEqual(wire[0]["content"] as? String, "系统提示")
        XCTAssertEqual(wire[1]["content"] as? String, "以下是此前对话的摘要：\n\n早先的摘要")
        XCTAssertEqual(wire[2]["content"] as? String, "二")
    }

    func testAnthropicKeepsTheRunningLoopsSignedThinkingAfterTheSummary() throws {
        let loop = ChatMessage(role: .assistant, parts: [
            .thinking("先列目录"), .thinkingSeal(.signature("sig-1", sealing: "先列目录")),
            .toolCall(ToolCall(id: "c9", name: "list_dir", argumentsJSON: "{}")),
            .toolResult(ToolResult(callID: "c9", name: "list_dir", outputText: "a.swift")),
        ])
        let messages = threeTurns() + [user("四"), loop]
        let compaction = ConversationCompaction(summary: "早先的摘要", coveredThroughID: messages[3].id)
        let request = GenerationRequest(
            modelID: "claude-sonnet-4-5",
            messages: ContextCompaction.requestMessages(messages, compaction: compaction),
            maxOutputTokens: 8192, thinkingBudgetTokens: 2048
        )
        let json = try RequestBuilderTests.jsonObject(from: AnthropicRequestBuilder.build(request))
        let wire = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        let opening = try XCTUnwrap(wire[0]["content"] as? [[String: Any]])
        XCTAssertEqual(opening.map { $0["text"] as? String }, ["以下是此前对话的摘要：\n\n早先的摘要", "三"], "摘要和第一条保留的用户消息并成一个 user 回合")
        let running = try XCTUnwrap(wire[3]["content"] as? [[String: Any]])
        XCTAssertEqual(running.first?["type"] as? String, "thinking")
        XCTAssertEqual(running.first?["signature"] as? String, "sig-1", "压缩不动正在跑的工具循环，签名思考照原样回传")
        XCTAssertNotNil(json["thinking"], "循环以签名思考开头，思考保持开启")
    }

    // MARK: Trigger

    func testAutoCompactionStartsAtEightyFivePercentOfTheWindow() {
        // 「字」 is one token each: three turns of 280 wide characters ≈ 6 × 280.
        let long = String(repeating: "字", count: 280)
        let messages = [user(long), answer(long), user(long), answer(long), user(long), answer(long)]
        let used = ContextCompaction.estimatedTokens(messages)
        XCTAssertEqual(used, 1680)
        XCTAssertFalse(ContextCompaction.shouldAutoCompact(messages, compaction: nil, contextWindow: 1977), "84.98%")
        XCTAssertTrue(ContextCompaction.shouldAutoCompact(messages, compaction: nil, contextWindow: 1976), "85.02%")
        XCTAssertFalse(ContextCompaction.shouldAutoCompact(messages, compaction: nil, contextWindow: nil), "不知道窗口就不自动压")
        XCTAssertFalse(ContextCompaction.shouldAutoCompact(Array(messages.prefix(4)), compaction: nil, contextWindow: 100),
                       "超了也要有足够早的内容才压")
    }

    func testTheEstimateCountsToolTrafficAndTheSummaryNotTheCoveredTurns() {
        let output = String(repeating: "x", count: 4000)
        XCTAssertEqual(ContextCompaction.estimatedTokens(toolTurn("c1", output: output)), 1000 + (8 + 12) / 4,
                       "工具输出和调用参数都占上下文")
        var conversation = Conversation(messages: threeTurns())
        let before = ContextCompaction.estimatedTokens(of: conversation)
        conversation.compaction = ConversationCompaction(summary: "短", coveredThroughID: conversation.messages[3].id)
        XCTAssertEqual(ContextCompaction.estimatedTokens(of: conversation),
                       ContextCompaction.estimatedTokens(ContextCompaction.requestMessages(conversation.messages, compaction: conversation.compaction)))
        XCTAssertNotEqual(ContextCompaction.estimatedTokens(of: conversation), before)
    }

    // MARK: Summarising

    func testTheSummaryRequestReadsTheOlderSummaryAndOnlyTheNewerMessages() throws {
        let messages = threeTurns() + [user("四"), answer("答四"), user("五"), answer("答五")]
        let older = ConversationCompaction(summary: "第一轮的摘要", coveredThroughID: messages[1].id)
        let cut = try XCTUnwrap(ContextCompaction.boundary(in: messages, after: older))
        XCTAssertEqual(cut, 6)
        let request = ContextCompaction.summaryRequest(
            modelID: "m1", messages: messages, boundary: cut, previous: older,
            contextWindow: 128_000, maxOutputTokens: 8_192
        )
        XCTAssertEqual(request.systemPrompt, ContextCompaction.instructions)
        XCTAssertTrue(request.tools.isEmpty, "摘要请求不带工具")
        XCTAssertNil(request.thinkingBudgetTokens)
        XCTAssertEqual(request.maxOutputTokens, 4_096)
        XCTAssertEqual(request.messages.count, 1)
        let text = request.messages[0].concatenatedText
        XCTAssertTrue(text.contains("【此前的摘要】\n第一轮的摘要"))
        XCTAssertTrue(text.contains("【用户】二") && text.contains("【助手】答三"))
        XCTAssertFalse(text.contains("【用户】一"), "旧摘要已覆盖的消息不再重读")
        XCTAssertFalse(text.contains("【用户】四"), "保留的最近两轮不进摘要")

        let newer = ContextCompaction.compaction(summary: "  一到三轮的摘要\n", messages: messages, boundary: cut, previous: older)
        XCTAssertEqual(newer.summary, "一到三轮的摘要")
        XCTAssertEqual(newer.coveredThroughID, messages[5].id, "新摘要取代旧的，覆盖到第三轮")
        XCTAssertEqual(ContextCompaction.requestMessages(messages, compaction: newer).map(\.concatenatedText),
                       ["以下是此前对话的摘要：\n\n一到三轮的摘要", "四", "答四", "五", "答五"])
        XCTAssertLessThan(newer.tokensAfter, newer.tokensBefore)
    }

    func testTheTranscriptDropsTheOldestMessagesOverBudgetButKeepsTheSummary() {
        let long = String(repeating: "字", count: 500)
        let messages = [user(long), answer(long), user(long), answer("最后一条")]
        let text = ContextCompaction.transcript(messages, previousSummary: "旧摘要", budgetTokens: 600)
        XCTAssertTrue(text.contains("【此前的摘要】\n旧摘要"))
        XCTAssertTrue(text.contains("（更早的 2 条消息太长，已省略）"))
        XCTAssertTrue(text.contains("【助手】最后一条"))
        XCTAssertEqual(text.components(separatedBy: long).count - 1, 1)
    }

    func testToolTrafficIsCappedInTheTranscript() {
        let huge = String(repeating: "y", count: 10_000)
        let text = ContextCompaction.transcript([user("跑一下"), toolTurn("c1", output: huge)], previousSummary: nil, budgetTokens: nil)
        XCTAssertTrue(text.contains("【调用工具 list_dir】{\"path\":\".\"}"))
        XCTAssertTrue(text.contains("…（已截断）"))
        XCTAssertLessThan(text.count, 2_300)
    }

    // MARK: Storage

    func testOldDocumentsOpenWithoutQueueOrCompaction() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"旧对话","messages":[]}"#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertTrue(conversation.queuedMessages.isEmpty)
        XCTAssertNil(conversation.compaction)
    }

    func testCompactionAndQueueRoundTrip() throws {
        var conversation = Conversation(messages: threeTurns())
        conversation.compaction = ConversationCompaction(summary: "摘要", coveredThroughID: conversation.messages[1].id, tokensBefore: 9, tokensAfter: 3)
        conversation.queuedMessages = [QueuedMessage(text: "追问", pastes: ["长文"], remote: true)]
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(decoded.compaction, conversation.compaction)
        XCTAssertEqual(decoded.queuedMessages, conversation.queuedMessages)
    }

    func testARelaunchHoldsWhatWasQueued() {
        var conversation = Conversation(messages: threeTurns())
        conversation.queuedMessages = [QueuedMessage(text: "追问")]
        XCTAssertTrue(conversation.closeInterruptedReplies())
        XCTAssertEqual(conversation.queuedMessages.map(\.isHeld), [true], "启动时没有回复在跑，排队的消息等用户决定")
        XCTAssertFalse(conversation.closeInterruptedReplies())
    }
}
