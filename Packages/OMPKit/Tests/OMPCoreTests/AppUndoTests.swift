import XCTest
@testable import OMPCore

/// Inverses restore exactly the fields their action changed, on a workspace
/// that may have moved on since, and refuse when the target is gone.
final class AppUndoTests: XCTestCase {
    private func workspace(_ conversations: [Conversation], projects: [Project] = []) -> AppUndoWorkspace {
        AppUndoWorkspace(conversations: conversations, projects: projects)
    }

    private func conversation(_ id: UUID, in workspace: AppUndoWorkspace) throws -> Conversation {
        try XCTUnwrap(workspace.conversations.first { $0.id == id })
    }

    // MARK: Archive

    func testUndoingAnArchiveKeepsMessagesThatArrivedSince() throws {
        let before = Conversation(title: "周报", isPinned: true)
        let entry = AppUndoEntry.toggledArchive(before)
        var archived = before
        archived.isArchived = true
        archived.isPinned = false
        // A background reply lands after the archive.
        archived.messages.append(ChatMessage(role: .assistant, parts: [.text("迟到的回复")]))
        archived.title = "周报（自动命名）"
        var state = workspace([archived])

        XCTAssertEqual(entry.inverse.apply(to: &state), .restored(AppUndoChanges(conversationIDs: [before.id])))
        let restored = try conversation(before.id, in: state)
        XCTAssertFalse(restored.isArchived)
        XCTAssertTrue(restored.isPinned, "archiving unpinned it; undo pins it again")
        XCTAssertEqual(restored.messages.count, 1, "the reply that arrived meanwhile stays")
        XCTAssertEqual(restored.title, "周报（自动命名）", "fields the archive did not touch are left alone")
    }

    func testUndoingAnUnarchiveLeavesThePinAlone() throws {
        let before = Conversation(title: "旧", isArchived: true)
        let entry = AppUndoEntry.toggledArchive(before)
        var current = before
        current.isArchived = false
        current.isPinned = true // pinned after unarchiving
        var state = workspace([current])

        _ = entry.inverse.apply(to: &state)
        let restored = try conversation(before.id, in: state)
        XCTAssertTrue(restored.isArchived)
        XCTAssertTrue(restored.isPinned, "unarchive never changed the pin, so undo must not either")
    }

    func testBulkArchiveUndoRestoresOnlyTheChatsItArchived() throws {
        let section = UUID()
        let a = Conversation(title: "a", isPinned: true, projectID: section)
        let b = Conversation(title: "b", projectID: section)
        let alreadyArchived = Conversation(title: "c", isArchived: true, projectID: section)
        // The action archived only a and b.
        let entry = try XCTUnwrap(AppUndoEntry.archived([a, b]))
        XCTAssertEqual(entry.confirmation, "已恢复 2 个对话")
        var state = workspace([a, b, alreadyArchived].map { var c = $0; c.isArchived = true; c.isPinned = false; return c })

        _ = entry.inverse.apply(to: &state)
        XCTAssertFalse(try conversation(a.id, in: state).isArchived)
        XCTAssertTrue(try conversation(a.id, in: state).isPinned)
        XCTAssertFalse(try conversation(b.id, in: state).isArchived)
        XCTAssertFalse(try conversation(b.id, in: state).isPinned)
        XCTAssertTrue(try conversation(alreadyArchived.id, in: state).isArchived, "archived before the bulk action")
    }

    func testBulkArchiveOfNothingRegistersNothing() {
        XCTAssertNil(AppUndoEntry.archived([]))
    }

    // MARK: Rename

    func testUndoingAnOlderRenameRestoresItsOwnPreviousTitleOnly() throws {
        let original = Conversation(title: "原名", goal: "目标")
        let first = try XCTUnwrap(AppUndoEntry.renamed(original, to: "第一次"))
        var renamed = original
        renamed.title = "第一次"
        let second = try XCTUnwrap(AppUndoEntry.renamed(renamed, to: "第二次"))
        renamed.title = "第二次"
        renamed.goal = "后来的目标"
        var state = workspace([renamed])

        _ = second.inverse.apply(to: &state)
        XCTAssertEqual(try conversation(original.id, in: state).title, "第一次")
        _ = first.inverse.apply(to: &state)
        XCTAssertEqual(try conversation(original.id, in: state).title, "原名")
        XCTAssertEqual(try conversation(original.id, in: state).goal, "后来的目标")
    }

    func testRenamingToTheSameTitleIsNotUndoable() {
        XCTAssertNil(AppUndoEntry.renamed(Conversation(title: "同名"), to: "同名"))
    }

    // MARK: Move

    func testMoveBackToTheOriginalProjectIncludingNone() throws {
        let project = Project(name: "OMP")
        let other = Project(name: "别处")
        let loose = Conversation(title: "未分组")
        let filed = Conversation(title: "在项目里", projectID: project.id)
        let intoOther = try XCTUnwrap(AppUndoEntry.moved(loose, to: other))
        let out = try XCTUnwrap(AppUndoEntry.moved(filed, to: nil))
        var state = workspace(
            [{ var c = loose; c.projectID = other.id; return c }(), { var c = filed; c.projectID = nil; return c }()],
            projects: [project, other]
        )

        _ = intoOther.inverse.apply(to: &state)
        _ = out.inverse.apply(to: &state)
        XCTAssertNil(try conversation(loose.id, in: state).projectID, "back to ungrouped")
        XCTAssertEqual(try conversation(filed.id, in: state).projectID, project.id)
    }

    func testMoveBackIntoADeletedProjectFailsAndChangesNothing() throws {
        let project = Project(name: "已删")
        let chat = Conversation(projectID: project.id)
        let entry = try XCTUnwrap(AppUndoEntry.moved(chat, to: nil))
        var state = workspace([{ var c = chat; c.projectID = nil; return c }()])

        guard case .failed = entry.inverse.apply(to: &state) else { return XCTFail("must refuse") }
        XCTAssertNil(try conversation(chat.id, in: state).projectID, "a dangling group id would hide the chat")
    }

    func testMovingToWhereItAlreadyIsIsNotUndoable() {
        XCTAssertNil(AppUndoEntry.moved(Conversation(), to: nil))
    }

    // MARK: Reorder

    func testReorderUndoRestoresOrderEvenAfterANewChatWasAdded() throws {
        let a = Conversation(title: "a")
        let b = Conversation(title: "b")
        var indexedA = a
        indexedA.sortIndex = 0
        var indexedB = b
        indexedB.sortIndex = 1
        let entry = try XCTUnwrap(AppUndoEntry.reordered([indexedA, indexedB], newIndexes: [b.id: 0, a.id: 1]))
        indexedA.sortIndex = 1
        indexedB.sortIndex = 0
        let newcomer = Conversation(title: "新")
        var state = workspace([newcomer, indexedB, indexedA])

        _ = entry.inverse.apply(to: &state)
        XCTAssertEqual(try conversation(a.id, in: state).sortIndex, 0)
        XCTAssertEqual(try conversation(b.id, in: state).sortIndex, 1)
        XCTAssertNil(try conversation(newcomer.id, in: state).sortIndex, "the new chat was never reordered")
    }

    func testReorderThatChangesNoIndexIsNotUndoable() {
        var a = Conversation()
        a.sortIndex = 0
        XCTAssertNil(AppUndoEntry.reordered([a], newIndexes: [a.id: 0]))
    }

    // MARK: Groups

    func testSectionDeleteUndoRestoresTheSectionAndItsMembership() throws {
        let first = Project(name: "前", order: 0, isCustomSection: true)
        let section = Project(name: "工作", order: 1, isCustomSection: true)
        let last = Project(name: "后", order: 2, isCustomSection: true)
        let elsewhere = Project(name: "别处")
        let member = Conversation(title: "成员", projectID: section.id)
        let refiled = Conversation(title: "后来挪走", projectID: section.id)
        let entry = AppUndoEntry.deletedGroup(section, position: 1, memberIDs: [member.id, refiled.id])
        // Deleting ungrouped both; one was filed elsewhere afterwards.
        var state = workspace(
            [{ var c = member; c.projectID = nil; return c }(), { var c = refiled; c.projectID = elsewhere.id; return c }()],
            projects: [first, last, elsewhere]
        )

        _ = entry.inverse.apply(to: &state)
        XCTAssertEqual(state.projects.map(\.id), [first.id, section.id, last.id, elsewhere.id], "back in its old slot")
        XCTAssertEqual(state.projects[1], section, "name, order and kind intact")
        XCTAssertEqual(try conversation(member.id, in: state).projectID, section.id)
        XCTAssertEqual(try conversation(refiled.id, in: state).projectID, elsewhere.id, "a later move wins")
    }

    func testUndoingASectionCreationRemovesItAndUngroupsWhatWasFiledIn() throws {
        let section = Project(name: "新", isCustomSection: true)
        let chat = Conversation(projectID: section.id)
        var state = workspace([chat], projects: [section])

        _ = AppUndoEntry.createdGroup(section).inverse.apply(to: &state)
        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertNil(try conversation(chat.id, in: state).projectID)
    }

    func testGroupRenameUndoFailsOnceTheGroupIsGone() throws {
        let project = Project(name: "旧名")
        let entry = try XCTUnwrap(AppUndoEntry.renamedGroup(project, to: "新名"))
        var state = workspace([])

        XCTAssertEqual(entry.inverse.apply(to: &state), .failed("无法撤销：项目已被删除"))
    }

    // MARK: Vanished targets

    func testUndoOnADeletedConversationFailsWithoutTouchingAnything() {
        let gone = Conversation(title: "已删")
        let survivor = Conversation(title: "还在", isArchived: true)
        var state = workspace([survivor])

        for entry in [AppUndoEntry.toggledArchive(gone), .toggledPin(gone), AppUndoEntry.renamed(gone, to: "x")!] {
            XCTAssertEqual(entry.inverse.apply(to: &state), .failed("无法撤销：对话已被删除"))
        }
        XCTAssertEqual(state.conversations, [survivor])
    }

    // MARK: Attachments

    func testAttachmentComesBackAtItsPositionInTheDraftItWasRemovedFrom() {
        let chat = UUID()
        let removed = MediaRef(kind: .image, relativePath: "b.png", mimeType: "image/png")
        let a = MediaRef(kind: .image, relativePath: "a.png", mimeType: "image/png")
        let c = MediaRef(kind: .file, relativePath: "c.txt", mimeType: "text/plain")
        let entry = AppUndoEntry.removedAttachment(removed, position: 1, conversationID: chat)

        var onScreen = AppUndoWorkspace(
            conversations: [Conversation(id: chat)], projects: [],
            composerConversationID: chat, composerAttachments: [a, c]
        )
        _ = entry.inverse.apply(to: &onScreen)
        XCTAssertEqual(onScreen.composerAttachments, [a, removed, c])

        // The user switched chats; the draft is parked, not on screen.
        var parked = AppUndoWorkspace(
            conversations: [Conversation(id: chat), Conversation()], projects: [],
            composerConversationID: UUID(), composerAttachments: [],
            parkedAttachments: [chat: [a]]
        )
        _ = entry.inverse.apply(to: &parked)
        XCTAssertEqual(parked.parkedAttachments[chat], [a, removed])
        XCTAssertTrue(parked.composerAttachments.isEmpty, "not dropped into another chat's draft")
    }

    func testAttachmentOfADeletedConversationCannotComeBack() {
        let ref = MediaRef(kind: .image, relativePath: "a.png", mimeType: "image/png")
        var state = AppUndoWorkspace(conversations: [], projects: [], composerConversationID: nil)
        let entry = AppUndoEntry.removedAttachment(ref, position: 0, conversationID: UUID())
        XCTAssertEqual(entry.inverse.apply(to: &state), .failed("无法撤销：对话已被删除"))
    }

    // MARK: Stack

    func testStackKeepsTheNewestWithinItsBoundAndPopsNewestFirst() {
        var stack = AppUndoStack(capacity: 3)
        let entries = (0..<5).map { AppUndoEntry(message: "\($0)", confirmation: "", inverse: .reorder([])) }
        entries.forEach { stack.push($0) }

        XCTAssertEqual(stack.entries.map(\.message), ["2", "3", "4"], "the oldest fall off")
        XCTAssertEqual(stack.top?.message, "4")
        XCTAssertEqual(stack.pop()?.message, "4")
        XCTAssertEqual(stack.pop()?.message, "3")
        XCTAssertEqual(stack.pop()?.message, "2")
        XCTAssertNil(stack.pop())
        XCTAssertEqual(AppUndoStack().capacity, 20)
    }
}
