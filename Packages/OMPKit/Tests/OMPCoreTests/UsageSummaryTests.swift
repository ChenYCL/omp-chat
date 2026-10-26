import XCTest
@testable import OMPCore

final class UsageSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(26, 10) }

    private func reply(_ input: Int, _ output: Int, reasoning: Int = 0, at createdAt: Date? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, parts: [], createdAt: createdAt ?? now,
                    usage: TokenUsage(inputTokens: input, outputTokens: output, reasoningTokens: reasoning))
    }

    private func summary(_ conversations: [Conversation], topLimit: Int = 5) -> UsageSummary {
        UsageSummary(conversations: conversations, now: now, calendar: calendar, topLimit: topLimit)
    }

    func testReasoningIsPartOfOutputNotAdded() {
        let conversation = Conversation(messages: [reply(100, 50, reasoning: 30), reply(10, 5)])
        let all = summary([conversation]).all
        XCTAssertEqual(all.inputTokens, 110)
        XCTAssertEqual(all.outputTokens, 55)
        XCTAssertEqual(all.reasoningTokens, 30)
        XCTAssertEqual(all.totalTokens, 165)
        XCTAssertEqual(TokenUsage(inputTokens: 100, outputTokens: 50, reasoningTokens: 30).totalTokens, 150)
    }

    func testRequestCountIgnoresUserMessagesAndMessagesWithoutUsage() {
        let user = ChatMessage(role: .user, parts: [], createdAt: now,
                               usage: TokenUsage(inputTokens: 999, outputTokens: 999))
        let noUsage = ChatMessage(role: .assistant, parts: [], createdAt: now)
        var conversation = Conversation(messages: [user, reply(1, 2), noUsage, reply(3, 4)])
        conversation.alternativeReplies = [reply(5, 6)]
        let all = summary([conversation]).all
        XCTAssertEqual(all.requests, 3)
        XCTAssertEqual(all.totalTokens, 1 + 2 + 3 + 4 + 5 + 6)
    }

    func testDayBoundaryAndSevenDayWindowEdge() {
        let conversation = Conversation(messages: [
            reply(1, 0, at: date(25, 23, 59)),   // yesterday
            reply(10, 0, at: date(26, 0, 1)),    // today
            reply(100, 0, at: date(20, 0, 0)),   // 6 days ago: inside 7 days
            reply(1000, 0, at: date(19, 23, 59)), // 7 days ago: outside 7 days, inside 30
            reply(10000, 0, at: date(27, 9, 0, month: 9)), // 29 days ago: inside 30
            reply(100000, 0, at: date(26, 23, 59, month: 9)), // 30 days ago: outside 30
        ])
        let usage = summary([conversation])
        XCTAssertEqual(usage.last7Days.totalTokens, 111)
        XCTAssertEqual(usage.last7Days.requests, 3)
        XCTAssertEqual(usage.last30Days.totalTokens, 11111)
        XCTAssertEqual(usage.all.totalTokens, 111111)
        XCTAssertEqual(usage.daily.last?.totalTokens, 10)
        XCTAssertEqual(usage.daily[usage.daily.count - 2].totalTokens, 1)
    }

    func testDailySeriesIsZeroFilledOldestFirst() {
        let conversation = Conversation(messages: [
            reply(5, 5, at: date(13, 12)),  // 13 days ago: first slot
            reply(7, 0, at: date(12, 12)),  // 14 days ago: not in the series
        ])
        let daily = summary([conversation]).daily
        XCTAssertEqual(daily.count, 14)
        XCTAssertEqual(daily.first?.date, date(13, 0))
        XCTAssertEqual(daily.last?.date, date(26, 0))
        XCTAssertEqual(daily.map(\.totalTokens), [10] + Array(repeating: 0, count: 13))
        XCTAssertEqual(zip(daily, daily.dropFirst()).allSatisfy { $0.date < $1.date }, true)
    }

    func testTopConversationsOrderAndLimit() {
        let conversations = (1...7).map { n in
            Conversation(title: "c\(n)", messages: [reply(n * 10, 0)])
        } + [Conversation(title: "empty", messages: [ChatMessage(role: .user, parts: [])])]
        let top = summary(conversations, topLimit: 5).topConversations
        XCTAssertEqual(top.map(\.title), ["c7", "c6", "c5", "c4", "c3"])
        XCTAssertEqual(top.first?.totals.totalTokens, 70)
        XCTAssertEqual(summary(conversations, topLimit: 20).topConversations.count, 7)
    }

    func testModelGroupingIncludesNilModel() {
        let conversations = [
            Conversation(modelID: "a", messages: [reply(10, 0)]),
            Conversation(modelID: "b", messages: [reply(1, 0)]),
            Conversation(modelID: "a", messages: [reply(5, 0), reply(5, 0)]),
            Conversation(modelID: nil, messages: [reply(3, 0)]),
            Conversation(modelID: "unused", messages: []),
        ]
        let groups = summary(conversations).byModel
        XCTAssertEqual(groups.map(\.modelID), ["a", nil, "b"])
        XCTAssertEqual(groups[0].conversations, 2)
        XCTAssertEqual(groups[0].totals.requests, 3)
        XCTAssertEqual(groups[0].totals.totalTokens, 20)
        XCTAssertEqual(groups[1].totals.totalTokens, 3)
    }
}
