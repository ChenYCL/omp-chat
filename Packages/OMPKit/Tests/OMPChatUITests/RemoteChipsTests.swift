import XCTest
import OMPCore
@testable import OMPChatUI

/// Maps a mirrored `RelayMessage` (attached mentions + 提及说明 notes) to
/// what the remote console renders: `RemoteMentionMapper` in
/// `RemoteChips.swift`. No view hierarchy, no network.
final class RemoteChipsTests: XCTestCase {
    private func message(
        attached: [RelayMentionAttachment]? = nil,
        mentionNotes: [String]? = nil
    ) -> RelayMessage {
        RelayMessage(
            id: UUID().uuidString, role: "user", text: "看看这个文件",
            ts: Date(), streaming: false,
            attached: attached, mentionNotes: mentionNotes
        )
    }

    func testChipsMapLabelsAndIcons() {
        let attached = [
            RelayMentionAttachment(kind: "file", title: "@README.md", truncated: false),
            RelayMentionAttachment(kind: "chat", title: "@旧对话", truncated: true),
            RelayMentionAttachment(kind: "skill", title: "$review", truncated: false),
        ]
        let chips = RemoteMentionMapper.chips(for: message(attached: attached))

        XCTAssertEqual(chips.count, 3)
        XCTAssertEqual(chips[0].title, "@README.md")
        XCTAssertEqual(chips[0].icon, "doc.text")
        XCTAssertFalse(chips[0].truncated)

        XCTAssertEqual(chips[1].title, "@旧对话")
        XCTAssertEqual(chips[1].icon, "bubble.left")
        XCTAssertTrue(chips[1].truncated)

        XCTAssertEqual(chips[2].title, "$review")
        XCTAssertEqual(chips[2].icon, "sparkles")
    }

    func testUnknownKindFallsBackToInfoIcon() {
        let attached = [RelayMentionAttachment(kind: "tab", title: "@网页标签", truncated: false)]
        let chips = RemoteMentionMapper.chips(for: message(attached: attached))
        XCTAssertEqual(chips.first?.icon, "globe")

        let nilKind = [RelayMentionAttachment(kind: nil, title: "未知", truncated: false)]
        let fallback = RemoteMentionMapper.chips(for: message(attached: nilKind))
        XCTAssertEqual(fallback.first?.icon, "info.circle")
    }

    func testNoAttachmentsProducesEmptyChips() {
        let chips = RemoteMentionMapper.chips(for: message())
        XCTAssertTrue(chips.isEmpty)
    }

    func testEmptyAttachedArrayDecodesToNilAndMapsToEmpty() throws {
        // RelayMessage's init collapses an empty array to nil so the wire
        // omits the key; confirm the round trip and that the mapper still
        // produces no chips.
        let empty = message(attached: [])
        XCTAssertNil(empty.attached)
        XCTAssertTrue(RemoteMentionMapper.chips(for: empty).isEmpty)

        let data = try JSONEncoder().encode(empty)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["attached"])
    }

    func testMentionNotesPassThroughAndEmptyCollapsesToNil() {
        let withNotes = message(mentionNotes: ["$missing 未找到技能", "@old.txt 内容被截断"])
        XCTAssertEqual(
            RemoteMentionMapper.notes(for: withNotes),
            ["$missing 未找到技能", "@old.txt 内容被截断"]
        )

        let noNotes = message(mentionNotes: [])
        XCTAssertNil(noNotes.mentionNotes)
        XCTAssertTrue(RemoteMentionMapper.notes(for: noNotes).isEmpty)
    }

    func testCombinedAccessibilityLabelIsStableJoin() {
        let attached = [
            RelayMentionAttachment(kind: "file", title: "@a.swift", truncated: false),
            RelayMentionAttachment(kind: "file", title: "@b.swift", truncated: false),
        ]
        let chips = RemoteMentionMapper.chips(for: message(attached: attached))
        let label = "附上的内容：" + chips.map(\.title).joined(separator: "、")
        XCTAssertEqual(label, "附上的内容：@a.swift、@b.swift")
    }

    func testRelayMessageRoundTripsAttachedAndNotes() throws {
        let original = message(
            attached: [RelayMentionAttachment(kind: "file", title: "@a.md", truncated: true)],
            mentionNotes: ["被截断的提及"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: data)
        XCTAssertEqual(decoded.attached, original.attached)
        XCTAssertEqual(decoded.mentionNotes, original.mentionNotes)
    }

    func testOlderWireJSONWithoutNewKeysDecodesFine() throws {
        // Simulates a host/relay that predates this change: no `attached` or
        // `mentionNotes` keys at all.
        let json = """
        {"id":"m1","role":"user","text":"hi","ts":"2026-01-01T00:00:00Z","streaming":false}
        """
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
        XCTAssertNil(decoded.attached)
        XCTAssertNil(decoded.mentionNotes)
        XCTAssertTrue(RemoteMentionMapper.chips(for: decoded).isEmpty)
        XCTAssertTrue(RemoteMentionMapper.notes(for: decoded).isEmpty)
    }
}
