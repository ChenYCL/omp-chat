import XCTest
import OMPCore
@testable import OMPChatUI

/// Composer mentions end to end: picked from the model's lists, resolved at
/// send time, and sent with the message. Never touches the network.
@MainActor
final class MentionModelTests: XCTestCase {
    private var libraryRoot: URL!
    private var project: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("omp-mention-model-\(UUID().uuidString)")
        libraryRoot = base.appendingPathComponent("media")
        project = URL(fileURLWithPath: AgentPathPolicy.canonical(base.appendingPathComponent("project").path))
        outside = URL(fileURLWithPath: AgentPathPolicy.canonical(base.appendingPathComponent("outside").path))
        for directory in [libraryRoot!, project!, outside!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write(project, "docs/说明.md", "第一行要点\n第二行")
        try write(project, ".agents/skills/review/SKILL.md", "---\nname: review\ndescription: 审查代码\n---\n按清单逐项审查。")
        try write(outside, "外部.txt", "外部内容")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot.deletingLastPathComponent())
    }

    private func write(_ base: URL, _ relative: String, _ text: String) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeModel(_ transport: FollowUpTransport) async throws -> (ChatAppModel, UUID) {
        let (model, id) = try await FollowUpHarness.makeModel(transport, libraryRoot: libraryRoot, tools: false)
        model.skillsHome = nil
        model.updateWorkingDirectory(id, project.path)
        return (model, id)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        try await FollowUpHarness.waitUntil(5, condition)
    }

    /// Picks 说明.md and the review skill into the draft the way the
    /// composer does; returns the two mentions.
    private func pickFileAndSkill(_ model: ChatAppModel, _ id: UUID) async throws -> (file: ComposerMention, skill: ComposerMention) {
        model.draft = "请看 @说明"
        let files = await model.mentionCandidates(query: "说明", trigger: "@", for: id)
        let doc = try XCTUnwrap(files.first { $0.section == .files })
        XCTAssertEqual(doc.title, "说明.md")
        XCTAssertEqual(doc.detail, "docs")
        model.pickMention(doc.mention)
        model.draft += "并按 $rev"
        let skills = await model.mentionCandidates(query: "rev", trigger: "$", for: id)
        let review = try XCTUnwrap(skills.first { $0.title == "review" })
        XCTAssertEqual(review.badge, "项目")
        model.pickMention(review.mention)
        return (doc.mention, review.mention)
    }

    func testASentMessageCarriesTheFileAndTheSkillWhileItsTextStaysReadable() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("看完了"))])
        let (model, id) = try await makeModel(transport)
        _ = try await pickFileAndSkill(model, id)
        XCTAssertEqual(model.draft, "请看 @说明.md 并按 $review ", "输入框里是可读的提及，不是 token")
        XCTAssertEqual(model.draftMentions.map(\.kind), [.file, .skill])

        model.send()
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        let sent = try XCTUnwrap(FollowUpHarness.transcript(transport.requests[0]).last)
        XCTAssertEqual(sent[0], "user")
        XCTAssertTrue(sent[1].hasPrefix("请看 @说明.md 并按 $review \n\n提及的文件 `docs/说明.md`：\n```md\n第一行要点\n第二行\n```"), sent[1])
        XCTAssertTrue(sent[1].contains("显式调用了技能「review」"))
        XCTAssertTrue(sent[1].contains("---\nname: review\ndescription: 审查代码\n---\n按清单逐项审查。"), "技能正文随消息发出")

        let stored = try XCTUnwrap(model.selectedConversation?.messages.first)
        XCTAssertEqual(stored.writtenText, "请看 @说明.md 并按 $review ", "气泡里只有用户写的字")
        XCTAssertEqual(stored.mentionAttachments.compactMap(\.mention?.kind), [.file, .skill], "文件和技能是两个卡片")
        XCTAssertEqual(stored.mentionNotes, [])
        XCTAssertEqual(model.selectedConversation?.title, "请看 @说明.md 并按 $review")
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.pickedMentions, [], "发出后表清空")
    }

    func testAReadableDraftSendsTheSameRequestAsTheTokensDid() async throws {
        let readable = FollowUpTransport([.body(FollowUpSSE.answer("好"))])
        let (model, id) = try await makeModel(readable)
        let (doc, review) = try await pickFileAndSkill(model, id)
        model.send()
        try await waitUntil { readable.requestCount == 1 && !model.isStreaming }

        // The draft as it used to be: the tokens themselves.
        let tokens = FollowUpTransport([.body(FollowUpSSE.answer("好"))])
        let (old, _) = try await makeModel(tokens)
        old.draft = "请看 \(doc.token) 并按 \(review.token) "
        old.send()
        try await waitUntil { tokens.requestCount == 1 && !old.isStreaming }

        let messages = try XCTUnwrap(readable.requests[0]["messages"] as? [[String: Any]])
        let before = try XCTUnwrap(tokens.requests[0]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, before.count)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: messages.last!, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: before.last!, options: .sortedKeys),
            "用户消息逐字节相同"
        )
        XCTAssertEqual(model.selectedConversation?.messages.first?.parts, old.selectedConversation?.messages.first?.parts)
    }

    func testPickedMentionsLiveBesideTheDraftOfTheirThread() async throws {
        let (model, first) = try await makeModel(FollowUpTransport([]))
        let (doc, review) = try await pickFileAndSkill(model, first)

        let second = model.newConversation().id
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.draftMentions, [])
        model.selectedConversationID = first
        XCTAssertEqual(model.draft, "请看 @说明.md 并按 $review ")
        XCTAssertEqual(model.draftMentions, [doc, review], "切回来提及还在")

        model.draft = "请看 @说明.m 并按 $review "
        XCTAssertEqual(model.draftMentions, [review], "改坏的提及变回普通文字")
        XCTAssertEqual(model.pickedMentions, [review])
        model.draft = "请看 @说明.md 并按 $review "
        XCTAssertEqual(model.draftMentions, [review], "再敲回同样的字也只是文字")
        XCTAssertEqual(model.draftForSending, "请看 @说明.md 并按 \(review.token) ")

        model.removeMention(review)
        XCTAssertEqual(model.draft, "请看 @说明.md 并按 ")
        XCTAssertEqual(model.draftMentions, [])

        model.setDraft("再看 @说明.md", mentions: [doc, review])
        XCTAssertEqual(model.pickedMentions, [doc], "不在文字里的不进表")
        XCTAssertNil(model.activeMentionQuery, "紧挨着提及不弹列表")

        model.deleteConversation(first)
        model.selectedConversationID = second
        XCTAssertEqual(model.pickedMentions, [])
    }

    func testEditAndResendKeepsTheMentionsTheTextStillNames() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("一")), .body(FollowUpSSE.answer("二"))])
        let (model, id) = try await makeModel(transport)
        _ = try await pickFileAndSkill(model, id)
        model.draft += "和 @gone.md"
        model.send()
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        let sent = try XCTUnwrap(model.selectedConversation?.messages.first)
        XCTAssertEqual(sent.mentionAttachments.count, 2)
        XCTAssertEqual(sent.writtenText, "请看 @说明.md 并按 $review 和 @gone.md", "没选过的 @gone.md 只是文字")

        model.editAndResend(sent.id, newText: "只看 @说明.md")
        try await waitUntil { transport.requestCount == 2 && !model.isStreaming }
        let edited = try XCTUnwrap(model.selectedConversation?.messages.first)
        XCTAssertEqual(edited.writtenText, "只看 @说明.md")
        XCTAssertEqual(edited.mentionAttachments.compactMap(\.mention?.kind), [.file], "删掉的技能不再附上")
        let resent = try XCTUnwrap(FollowUpHarness.transcript(transport.requests[1]).last)
        XCTAssertTrue(resent[1].hasPrefix("只看 @说明.md\n\n提及的文件 `docs/说明.md`："), resent[1])
        XCTAssertFalse(resent[1].contains("按清单逐项审查"))
    }

    func testExportsAndThePhoneShowWhatTheUserWrote() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("好"))])
        let (model, id) = try await makeModel(transport)
        _ = try await pickFileAndSkill(model, id)
        model.send()
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        let conversation = try XCTUnwrap(model.selectedConversation)

        let markdown = model.exportMarkdown(conversation)
        XCTAssertTrue(markdown.contains("请看 @说明.md 并按 $review \n\n<details><summary>@说明.md</summary>\n\n提及的文件 `docs/说明.md`："), markdown)
        XCTAssertTrue(markdown.contains("<details><summary>$review</summary>"))

        let html = model.exportHTML(conversation)
        XCTAssertTrue(html.contains("<div class=\"bubble\">请看 @说明.md 并按 $review <details class=\"mention\"><summary>@说明.md</summary><pre>提及的文件"))

        let json = model.exportJSON(conversation)
        let reimported = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertEqual(reimported.messages.first?.mentionAttachments.count, 2, "JSON 导出带着标记，导回来还是卡片")

        let phone = try XCTUnwrap(model.relaySnapshot().conversations.first { $0.id == id.uuidString })
        XCTAssertEqual(phone.messages.first?.text, "请看 @说明.md 并按 $review ", "手机只看到用户写的字")
    }

    func testOtherChatsAndOpenTabsAreOfferedAndAChatIsQuoted() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("答"))])
        let (model, id) = try await makeModel(transport)
        await model.sendNow(text: "旧对话里的问题", attachments: [])
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }

        let other = model.newConversation()
        let offered = await model.mentionCandidates(query: "", trigger: "@", for: other.id)
        XCTAssertFalse(offered.contains { $0.section == .files }, "空查询不列文件")
        XCTAssertFalse(offered.contains { $0.mention.target == other.id.uuidString }, "不列当前对话")
        let chat = try XCTUnwrap(offered.first { $0.section == .chats && $0.mention.target == id.uuidString })
        XCTAssertEqual(chat.title, "旧对话里的问题")
        #if os(macOS)
        XCTAssertTrue(offered.contains { $0.section == .tabs && $0.detail == ChatAppModel.browserHomeURL })
        #endif

        let resolution = await model.resolveMentions(in: "接着 \(chat.mention.token)", for: other.id)
        XCTAssertEqual(resolution.notes, [])
        XCTAssertEqual(resolution.attachments.map(\.text), ["\n\n提及的对话「旧对话里的问题」（最近 2 条消息）：\n```\n用户：旧对话里的问题\n助手：答\n```"])
    }

    func testAPhoneSendGoesAsTyped() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("好"))])
        let (model, _) = try await makeModel(transport)
        let token = try XCTUnwrap(ComposerMention(kind: .file, label: "说明.md", target: "docs/说明.md")).token
        await model.sendNow(text: "看 \(token)", attachments: [], remote: true)
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[0]).last, ["user", "看 \(token)"], "手机发的不读文件、不改文字")
    }

    func testWhatCannotBeAttachedIsANoteAndTheMessageStillGoes() async throws {
        let transport = FollowUpTransport([.body(FollowUpSSE.answer("好"))])
        let (model, _) = try await makeModel(transport)
        let token = try XCTUnwrap(ComposerMention(kind: .file, label: "gone.md", target: "gone.md")).token
        model.draft = "看 \(token)"
        model.send()
        try await waitUntil { transport.requestCount == 1 && !model.isStreaming }
        XCTAssertEqual(FollowUpHarness.transcript(transport.requests[0]).last,
                       ["user", "看 @gone.md\n\n提及说明：\n- 文件 gone.md 已不存在，没有附上。"])
        XCTAssertNil(model.errorMessage)
        let stored = try XCTUnwrap(model.selectedConversation?.messages.first)
        XCTAssertEqual(stored.writtenText, "看 @gone.md")
        XCTAssertEqual(stored.mentionNotes, ["文件 gone.md 已不存在，没有附上。"], "说明显示在气泡下面")
    }

    func testAFolderThatCannotBeListedReportsTheFileSearchError() async throws {
        let (model, id) = try await makeModel(FollowUpTransport([]))
        model.updateWorkingDirectory(id, project.appendingPathComponent("missing").path)
        let result = await model.mentionSearch(query: "说明", trigger: "@", for: id)
        XCTAssertTrue(result.fileSearchFailed)
        XCTAssertFalse(result.candidates.contains { $0.section == .files })
    }

    func testAFileOutsideTheFolderAttachesOnlyWhenPickedByItsPath() async throws {
        let (model, id) = try await makeModel(FollowUpTransport([]))
        let path = outside.appendingPathComponent("外部.txt").path
        let typed = try XCTUnwrap(ComposerMention(kind: .file, label: "外部.txt", target: path))
        let before = await model.resolveMentions(in: typed.token, for: id)
        XCTAssertTrue(before.blocks.isEmpty)
        XCTAssertEqual(before.notes, ["文件 \(path) 不在工作目录里，只有从列表里选取的文件才会附上。"])

        model.draft = "@" + path
        let candidates = await model.mentionCandidates(query: path, trigger: "@", for: id)
        let picked = try XCTUnwrap(candidates.first { $0.section == .files })
        XCTAssertEqual(picked.mention.target, path)
        model.pickMention(picked.mention)
        XCTAssertEqual(model.draft, "@外部.txt ")
        let after = await model.resolveMentions(in: model.draftForSending, for: id)
        XCTAssertEqual(after.notes, [])
        XCTAssertTrue(after.blocks.first?.text.contains("外部内容") == true)
    }

    func testAQueuedFollowUpKeepsItsMentionsAndEditPutsTheTokensBack() async throws {
        let gate = TestGate()
        let transport = FollowUpTransport([.gated(gate, FollowUpSSE.answer("第一条的回答"))])
        let (model, id) = try await makeModel(transport)
        await model.sendNow(text: "第一条", attachments: [])
        try await waitUntil { transport.requestCount == 1 }

        let mention = try XCTUnwrap(ComposerMention(kind: .file, label: "说明.md", target: "docs/说明.md"))
        await model.sendNow(text: "再看 \(mention.token)", attachments: [])
        let queued = try XCTUnwrap(model.queuedMessages(for: id).first)
        XCTAssertEqual(queued.text, "再看 \(mention.token)")
        XCTAssertEqual(queued.mentions.count, 1)
        XCTAssertTrue(queued.mentions[0].text.contains("第一行要点"), "排队时就读好文件")
        XCTAssertEqual(queued.message.parts.first, .text("再看 @说明.md"))
        XCTAssertEqual(queued.message.mentionAttachments.map(\.mention), [mention])

        model.editQueued(queued.id, in: id)
        XCTAssertEqual(model.draft, "再看 @说明.md", "编辑回到输入框是可读的")
        XCTAssertEqual(model.draftMentions, [mention], "编辑把提及放回输入框，下次发送重新读取")
        gate.release()
        try await waitUntil { !model.isStreaming }
    }

    #if os(macOS)
    func testATabMentionReadsTheLivePageAtSendTime() async throws {
        let (model, id) = try await makeModel(FollowUpTransport([]))
        let tab = try XCTUnwrap(model.browserTabs.tabs.first)
        let token = try XCTUnwrap(ComposerMention(kind: .tab, label: tab.displayTitle, target: tab.id.uuidString)).token

        let closed = await model.resolveMentions(in: token, for: id)
        XCTAssertEqual(closed.notes, ["标签页「\(tab.displayTitle)」的页面没有在浏览器面板里打开，只附上了标题和地址。"])

        var asked: [UUID] = []
        let owner = UUID()
        model.setBrowserPageReader({ tabID in
            asked.append(tabID)
            return "页面正文"
        }, owner: owner)
        let open = await model.resolveMentions(in: token, for: id)
        XCTAssertEqual(asked, [tab.id])
        XCTAssertEqual(open.notes, [])
        XCTAssertTrue(open.blocks.first?.text.contains("地址：\(tab.url)\n\n页面正文") == true)

        model.setBrowserPageReader(nil, owner: owner)
        let gone = await model.resolveMentions(in: token, for: id)
        XCTAssertEqual(gone.notes, closed.notes, "面板关掉后不再读页面")
    }
    #endif
}
