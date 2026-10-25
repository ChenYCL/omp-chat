import XCTest
@testable import OMPChatUI
import OMPCore

/// Import is what makes an exported backup worth having; it had no UI until now.
@MainActor
final class ImportConversationTests: XCTestCase {
    private func model() -> ChatAppModel {
        ChatAppModel(store: FileConversationStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-import-\(UUID().uuidString)", isDirectory: true)))
    }

    private func json(_ conversation: Conversation) throws -> String {
        let data = try JSONEncoder().encode(conversation)
        return String(decoding: data, as: UTF8.self)
    }

    func testImportAddsAndSelectsTheConversation() throws {
        let source = Conversation(title: "备份的对话", messages: [
            ChatMessage(role: .user, parts: [.text("你好")]),
        ])
        let m = model()
        let imported = try m.importConversation(from: json(source))
        XCTAssertEqual(imported.title, "备份的对话")
        XCTAssertEqual(m.conversations.count, 1)
        XCTAssertEqual(m.selectedConversationID, imported.id)
    }

    func testImportingTheSameIDRenamesInsteadOfOverwriting() throws {
        let source = Conversation(title: "原件", messages: [])
        let m = model()
        _ = try m.importConversation(from: json(source))
        let again = try m.importConversation(from: json(source))
        XCTAssertEqual(m.conversations.count, 2, "同 id 再导入应新增而不是覆盖")
        XCTAssertEqual(again.title, "原件 (导入)")
        XCTAssertNotEqual(again.id, source.id)
    }

    func testMalformedJSONThrowsInsteadOfAddingAnEmptyChat() throws {
        let m = model()
        XCTAssertThrowsError(try m.importConversation(from: "{\"nope\":1}"))
        XCTAssertTrue(m.conversations.isEmpty)
    }

    func testExportedJSONImportsBack() throws {
        // The round trip is what the export/import pair promises; a mismatch
        // here means a backup nobody can restore.
        let m = model()
        let source = Conversation(title: "往返", messages: [
            ChatMessage(role: .user, parts: [.text("导出再导入")]),
            ChatMessage(role: .assistant, parts: [.text("好的")], status: .complete),
        ])
        let exported = m.exportJSON(source)
        XCTAssertFalse(exported.isEmpty)
        let imported = try m.importConversation(from: exported)
        XCTAssertEqual(imported.title, "往返")
        XCTAssertEqual(imported.messages.count, 2)
        XCTAssertEqual(imported.messages.first?.concatenatedText, "导出再导入")
    }
}
