import Foundation
import XCTest
@testable import OMPCore

/// Wire-format tests for the additive `thinking` / `activity` fields on
/// `RelayMessage` and `RelayActivity`: old payloads without the fields must
/// keep decoding, new payloads round trip, and the wire caps hold.
final class RelayModelsTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let timestamp = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

    func testOldJSONWithoutNewFieldsDecodes() throws {
        let json = """
        {"id":"m1","role":"assistant","text":"正文","ts":"2026-10-25T12:00:00Z","streaming":false}
        """
        let message = try decoder.decode(RelayMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.text, "正文")
        XCTAssertNil(message.thinking)
        XCTAssertNil(message.activity)

        // Re-encoding an old payload must not grow the new keys.
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any]
        XCTAssertNil(raw?["thinking"])
        XCTAssertNil(raw?["activity"])
    }

    func testRoundTripWithNewFields() throws {
        let activity = RelayActivity(
            id: "call_1", name: "edit_file", summary: "已编辑 AppDelegate.swift",
            status: "ok", added: 12, removed: 3,
            detail: "{\"file_path\":\"/tmp/AppDelegate.swift\"}\n--- a\n+++ b"
        )
        let message = RelayMessage(
            id: "m2", role: "assistant", text: "改好了", ts: timestamp, streaming: false,
            thinking: "先找到文件，再替换。", activity: [activity]
        )
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(RelayMessage.self, from: data)
        XCTAssertEqual(decoded, message)

        // Wire shape: arrays of objects, empty optionals stay absent.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let wireActivity = ((raw?["activity"] as? [[String: Any]]) ?? []).first ?? [:]
        XCTAssertEqual(wireActivity["summary"] as? String, "已编辑 AppDelegate.swift")
        XCTAssertEqual(wireActivity["added"] as? Int, 12)
        XCTAssertEqual(wireActivity["removed"] as? Int, 3)
        XCTAssertEqual(Set(wireActivity.keys).isSuperset(of: ["id", "name", "summary", "status", "added", "removed", "detail"]), true)
    }

    func testEmptyThinkingAndActivityAreOmitted() throws {
        let message = RelayMessage(
            id: "m3", role: "assistant", text: " plain ", ts: timestamp, streaming: false,
            thinking: "", activity: []
        )
        XCTAssertEqual(message.thinking, nil)
        XCTAssertEqual(message.activity, nil)
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any]
        XCTAssertEqual(raw?.keys.contains("thinking"), false)
        XCTAssertEqual(raw?.keys.contains("activity"), false)
    }

    func testEmptyActivityDetailIsOmitted() throws {
        let activity = RelayActivity(
            id: "call_2", name: "read_file", summary: "已读 main.swift", status: "ok", detail: ""
        )
        XCTAssertEqual(activity.detail, nil)
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(activity)) as? [String: Any]
        XCTAssertEqual(raw?.keys.contains("detail"), false)
    }

    func testThinkingCapEnforced() throws {
        let oversized = RelayMessage(
            id: "m4", role: "assistant", text: " t ", ts: timestamp, streaming: false,
            thinking: String(repeating: "a", count: RelayMessage.maxThinkingBytes + 4096)
        )
        XCTAssertEqual(oversized.thinking?.utf8.count, RelayMessage.maxThinkingBytes)

        let json = """
        {"id":"m4","role":"assistant","text":"t","ts":"2026-10-25T12:00:00Z","streaming":false,"thinking":"\(String(repeating: "b", count: RelayMessage.maxThinkingBytes + 512))"}
        """
        let decoded = try decoder.decode(RelayMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.thinking?.utf8.count, RelayMessage.maxThinkingBytes)
    }

    func testActivityDetailCapEnforced() throws {
        let oversized = RelayActivity(
            id: "call_3", name: "bash", summary: "已运行 make", status: "ok",
            detail: String(repeating: "x", count: RelayActivity.maxDetailBytes + 256)
        )
        XCTAssertEqual(oversized.detail?.utf8.count, RelayActivity.maxDetailBytes)
    }

    func testActivityCapEnforced() throws {
        let items = (0..<80).map { RelayActivity(id: "\($0)", name: "tool", summary: "已运行 t\($0)", status: "ok") }
        let message = RelayMessage(id: "m5", role: "assistant", text: " a ", ts: timestamp, streaming: false, activity: items)
        XCTAssertEqual(message.activity?.count, RelayActivity.maxPerMessage)
        XCTAssertEqual(message.activity?.first?.id, "0", "keeps the earliest operations")

        let wire = try JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any]
        XCTAssertEqual((wire?["activity"] as? [[String: Any]])?.count, RelayActivity.maxPerMessage)
    }

    func testMultibyteDetailTruncatesWithoutSplittingCharacters() throws {
        let detail = String(repeating: "你", count: RelayActivity.maxDetailBytes) // 3 bytes each
        let activity = RelayActivity(id: "call_4", name: "edit", summary: "已编辑 中文.md", status: "ok", detail: detail)
        let capped = try XCTUnwrap(activity.detail)
        XCTAssertLessThanOrEqual(capped.utf8.count, RelayActivity.maxDetailBytes)
        XCTAssertEqual(capped, String(decoding: capped.utf8, as: UTF8.self), "no replacement characters")
    }

    func testRelayActivityDecodesFromSparseJSON() throws {
        let json = """
        {"summary":"已搜索 relay"}
        """
        let activity = try decoder.decode(RelayActivity.self, from: Data(json.utf8))
        XCTAssertEqual(activity.name, "")
        XCTAssertEqual(activity.summary, "已搜索 relay")
        XCTAssertEqual(activity.status, "ok")
        XCTAssertNil(activity.added)
        XCTAssertNil(activity.detail)
    }
}
