import XCTest
import OMPCore
@testable import OMPChatUI

/// Sidebar actions register undo at the model, so every caller gets it;
/// a paired phone's commands do not.
@MainActor
final class UndoModelTests: XCTestCase {
    private func makeModel(store: InMemoryConversationStore = InMemoryConversationStore()) async -> ChatAppModel {
        let model = ChatAppModel(
            store: store,
            secrets: InMemorySecretStore(),
            mediaLibrary: MediaLibrary(rootURL: FileManager.default.temporaryDirectory),
            transport: URLSessionTransport()
        )
        await model.bootstrap()
        return model
    }

    func testArchiveShowsAToastAndUndoRestoresAndPersistsIt() async throws {
        let store = InMemoryConversationStore()
        let model = await makeModel(store: store)
        let id = try XCTUnwrap(model.selectedConversationID)
        model.renameConversation(id, title: "周报")

        model.toggleArchive(id)
        XCTAssertEqual(model.undoToast?.message, "已归档「周报」")
        XCTAssertEqual(model.undoToast?.offersUndo, true)

        XCTAssertEqual(model.undoLast(), "已恢复对话")
        XCTAssertEqual(model.conversations.first { $0.id == id }?.isArchived, false)
        XCTAssertEqual(model.undoToast?.message, "已恢复对话")
        XCTAssertEqual(model.undoToast?.offersUndo, false, "the confirmation has no 撤销")
        XCTAssertEqual(model.undoStack.top?.message, "已重命名为「周报」", "only the archive was taken back")

        try await Task.sleep(for: .milliseconds(200))
        let saved = try await store.loadAll().first { $0.id == id }
        XCTAssertEqual(saved?.isArchived, false, "the undo was saved, not only shown")
    }

    func testTwoRenamesUndoNewestFirst() async throws {
        let model = await makeModel()
        let id = try XCTUnwrap(model.selectedConversationID)
        let original = try XCTUnwrap(model.selectedConversation?.title)

        model.renameConversation(id, title: "第一次")
        model.renameConversation(id, title: "第二次")
        XCTAssertEqual(model.undoLast(), "已恢复对话名称")
        XCTAssertEqual(model.selectedConversation?.title, "第一次")
        model.undoLast()
        XCTAssertEqual(model.selectedConversation?.title, original)
        XCTAssertNil(model.undoLast(), "nothing left")
    }

    func testDeletingASectionAndUndoingBringsBackItsChats() async throws {
        let model = await makeModel()
        let first = try XCTUnwrap(model.selectedConversationID)
        let second = model.newConversation().id
        let section = model.createCustomSection(name: "工作")
        model.moveConversation(first, toCustomSection: section.id)
        model.moveConversation(second, toCustomSection: section.id)

        model.deleteCustomSection(section.id)
        XCTAssertEqual(model.undoToast?.message, "已删除分区「工作」")
        XCTAssertTrue(model.conversations(inCustomSection: section.id).isEmpty)

        XCTAssertEqual(model.undoLast(), "已恢复分区")
        XCTAssertEqual(model.orderedCustomSections.map(\.id), [section.id])
        XCTAssertEqual(Set(model.conversations(inCustomSection: section.id).map(\.id)), [first, second])
    }

    func testUndoOfADeletedChatSaysSoAndDropsTheEntry() async throws {
        let model = await makeModel()
        let id = model.newConversation().id
        model.togglePin(id)
        model.deleteConversation(id)

        XCTAssertEqual(model.undoLast(), "无法撤销：对话已被删除")
        XCTAssertEqual(model.undoToast?.message, "无法撤销：对话已被删除")
        XCTAssertNil(model.undoStack.top, "a failed undo is not retried forever")
    }

    func testRemovedAttachmentComesBackInPlace() async throws {
        let model = await makeModel()
        let a = MediaRef(kind: .image, relativePath: "a.png", mimeType: "image/png")
        let b = MediaRef(kind: .image, relativePath: "b.png", mimeType: "image/png")
        model.draftAttachments = [a, b]

        model.removeAttachment(a.id)
        XCTAssertEqual(model.draftAttachments, [b])
        XCTAssertEqual(model.undoLast(), "已恢复附件")
        XCTAssertEqual(model.draftAttachments, [a, b])
    }

    func testPhoneCommandsRegisterNoUndoButLocalActionsDo() async throws {
        let model = await makeModel()
        let id = try XCTUnwrap(model.selectedConversationID)

        await model.handleRelayCommand(.togglePin(conversationID: id.uuidString))
        await model.handleRelayCommand(.rename(conversationID: id.uuidString, title: "手机改的"))
        await model.handleRelayCommand(.toggleArchive(conversationID: id.uuidString))
        XCTAssertEqual(model.conversations.first { $0.id == id }?.title, "手机改的", "the commands did run")
        XCTAssertNil(model.undoStack.top, "no undo for what the phone did")
        XCTAssertNil(model.undoToast, "no toast on the Mac either")

        model.toggleArchive(id)
        XCTAssertNotNil(model.undoStack.top, "suppression ended with the phone command")
    }

    func testDismissingTheToastKeepsTheHistory() async throws {
        let model = await makeModel()
        let id = try XCTUnwrap(model.selectedConversationID)
        model.togglePin(id)

        model.dismissUndoToast()
        XCTAssertNil(model.undoToast)
        XCTAssertEqual(model.undoLast(), "已取消置顶")
        XCTAssertEqual(model.selectedConversation?.isPinned, false)
    }
}
