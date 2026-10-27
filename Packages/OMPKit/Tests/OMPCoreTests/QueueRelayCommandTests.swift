import XCTest
@testable import OMPCore

/// The phone's side of queued follow-ups: the two commands on the wire and
/// the queue in the snapshot.
final class QueueRelayCommandTests: XCTestCase {
    func testQueueCommandsRoundTripOnTheWire() throws {
        let commands: [RelayCommand] = [
            .sendQueuedNow(conversationID: "C1", queuedID: "Q1"),
            .removeQueued(conversationID: "C1", queuedID: "Q1"),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(RelayCommandWire(command))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["conversationID"] as? String, "C1")
            XCTAssertEqual(object["queuedID"] as? String, "Q1")
            XCTAssertEqual(try JSONDecoder().decode(RelayCommandWire.self, from: data).command, command)
        }
        let raw = #"{"kind":"sendQueuedNow","conversationID":"C1","queuedID":"Q1"}"#
        XCTAssertEqual(try JSONDecoder().decode(RelayCommandWire.self, from: Data(raw.utf8)).command,
                       .sendQueuedNow(conversationID: "C1", queuedID: "Q1"), "hub 原样转发的 JSON 能解出来")
    }

    func testAQueueCommandWithoutBothIDsIsABadCommand() {
        XCTAssertNil(RelayCommandWire(kind: "sendQueuedNow", conversationID: "C1").command)
        XCTAssertNil(RelayCommandWire(kind: "sendQueuedNow", conversationID: "C1", queuedID: "").command)
        XCTAssertNil(RelayCommandWire(kind: "removeQueued", queuedID: "Q1").command)
    }

    func testTheSnapshotCarriesTheQueueOnlyWhenThereIsOne() throws {
        let idle = RelayConversation(id: "C1", title: "对话", updatedAt: Date(), project: nil, isStreaming: false, messages: [])
        let idleJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(idle)) as? [String: Any])
        XCTAssertNil(idleJSON["queued"], "空队列不编码，老客户端的快照不变")
        XCTAssertNil(idleJSON["isCompacting"])

        let busy = RelayConversation(
            id: "C1", title: "对话", updatedAt: Date(), project: nil, isStreaming: true, messages: [],
            queued: [RelayQueuedMessage(id: "Q1", text: "再查一下", hasAttachments: true, held: true)],
            isCompacting: true
        )
        let decoded = try JSONDecoder().decode(RelayConversation.self, from: JSONEncoder().encode(busy))
        XCTAssertEqual(decoded.queued, busy.queued)
        XCTAssertTrue(decoded.isCompacting)

        let old = #"{"id":"C1","title":"对话","isStreaming":false,"messages":[]}"#
        let legacy = try JSONDecoder().decode(RelayConversation.self, from: Data(old.utf8))
        XCTAssertTrue(legacy.queued.isEmpty)
        XCTAssertFalse(legacy.isCompacting)
    }
}
