import XCTest
@testable import OMPCore

final class ComposerMentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-mention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Physical path, so symlink checks compare like with like.
        root = URL(fileURLWithPath: AgentPathPolicy.canonical(root.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        try write(relative, Data(text.utf8))
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func file(_ target: String, _ label: String? = nil) -> ComposerMention {
        ComposerMention(kind: .file, label: label ?? (target as NSString).lastPathComponent, target: target)!
    }

    private func resolve(_ mentions: [ComposerMention], _ sources: MentionSources? = nil, limits: MentionLimits = .standard) -> MentionResolution {
        MentionResolver.resolve(mentions, sources: sources ?? MentionSources(workingDirectory: root.path, home: "/nonexistent-home"), limits: limits)
    }

    // MARK: Trigger grammar

    func testTriggersAtAWordStartIncludingNextToCJK() throws {
        let cases: [(String, Character, String)] = [
            ("@", "@", ""),
            ("请看 @说明", "@", "说明"),
            ("请看@说明", "@", "说明"),
            ("（@readme", "@", "readme"),
            ("first line\n@src/a", "@", "src/a"),
            ("$", "$", ""),
            ("用$rev", "$", "rev"),
            ("then $review", "$", "review"),
        ]
        for (text, trigger, query) in cases {
            let active = try XCTUnwrap(ComposerMention.activeQuery(in: text), text)
            XCTAssertEqual(active.trigger, trigger, text)
            XCTAssertEqual(active.query, query, text)
            XCTAssertEqual(String(text[active.range]), String(trigger) + query, text)
        }
    }

    func testNoTriggerInEmailsURLsWordsOrAfterABackslash() {
        let texts = [
            "a@b", "mail name@example.com", "foo@", "1@2", "https://x.com/@me", "https://例子.cn/路径@me",
            "\\@readme", "[@readme", "@@x", "@a@b", "word.@x", "$5", "a$b", "$$x", "@readme ", "$rev\n",
            "[@a.md](file:a.md)@b", "",
        ]
        for text in texts {
            XCTAssertNil(ComposerMention.activeQuery(in: text), text)
        }
    }

    // MARK: Draft

    private let skill = ComposerMention(kind: .skill, label: "review", target: "/x/.agents/skills/review/SKILL.md")!

    private func chat(_ label: String) -> ComposerMention {
        ComposerMention(kind: .chat, label: label, target: UUID().uuidString)!
    }

    func testAPickedMentionReadsAsItsNameAndSendsAsItsToken() throws {
        let mention = try XCTUnwrap(ComposerMention(kind: .file, label: "说明 [草稿].md", target: "docs/说明 (1).md"))
        var draft = MentionDraft(text: "请看 @说")
        draft.insert(mention)
        XCTAssertEqual(draft.text, "请看 @说明 [草稿].md ")
        XCTAssertNil(draft.activeQuery, "选中后列表关闭")
        XCTAssertEqual(draft.mentions, [mention])
        XCTAssertEqual(draft.tokenized, "请看 [@说明 \\[草稿\\].md](file:docs/说明%20%281%29.md) ")

        draft.text += "并按 $re"
        draft.insert(skill)
        XCTAssertEqual(draft.text, "请看 @说明 [草稿].md 并按 $review ")
        XCTAssertEqual(draft.mentions, [mention, skill])
        XCTAssertEqual(ComposerMention.mentions(in: draft.tokenized), [mention, skill], "发出的文字里是两个完整的提及")
        XCTAssertEqual(ComposerMention.readable(draft.tokenized), draft.text, "记录里读到的就是输入框里的样子")

        let back = MentionDraft(tokenized: draft.tokenized)
        XCTAssertEqual(back.text, draft.text, "排队后编辑，回到输入框还是可读的")
        XCTAssertEqual(back.picked, [mention, skill])
    }

    func testAPickWithNoQueryAppendsAndAMentionIsNotASearch() throws {
        var draft = MentionDraft(text: "看看")
        draft.insert(file("a.md"))
        XCTAssertEqual(draft.text, "看看 @a.md ")
        var empty = MentionDraft()
        empty.insert(file("a.md"))
        XCTAssertEqual(empty.text, "@a.md ")

        // The space after a mention deleted: the trigger is the mention's.
        var glued = MentionDraft(text: "看 @a.md", picked: [file("a.md")])
        XCTAssertNil(glued.activeQuery)
        XCTAssertEqual(MentionDraft(text: "看 @a.m", picked: [file("a.md")]).activeQuery?.query, "a.m", "改坏了就重新搜索")
        glued.insert(file("b.md"))
        XCTAssertEqual(glued.text, "看 @a.md @b.md ")
    }

    func testEditingAMentionTurnsItBackIntoPlainText() {
        let a = file("docs/a.md")
        let text = "看 @a.md 好吗"
        XCTAssertEqual(MentionDraft(text: text, picked: [a]).mentions, [a])
        XCTAssertEqual(MentionDraft(text: text + "，再加一句 @a.md", picked: [a]).mentions, [a], "接着打字、再写一遍都不影响")
        for edited in ["看 @a.m 好吗", "看 @a.mdx 好吗", "看 @a.md.bak 好吗", "看 x@a.md 好吗", "看 @@a.md 好吗", "看 @a.md_2 好吗", "看 @a.md/ 好吗"] {
            let broken = MentionDraft(text: edited, picked: [a])
            XCTAssertTrue(broken.mentions.isEmpty, edited)
            XCTAssertEqual(broken.tokenized, edited, "残缺的提及原样发出：\(edited)")
            XCTAssertTrue(broken.pruned.picked.isEmpty, edited)
        }
        for text in ["看@a.md。", "看 @a.md.", "(@a.md)", "@a.md，然后", "看@a.md吧", "**@a.md**", "@a.md\n下一行"] {
            XCTAssertEqual(MentionDraft(text: text, picked: [a]).mentions, [a], "标点、汉字、换行前仍是提及：\(text)")
        }
        // Pruned once broken, the same characters typed again are text.
        let pruned = MentionDraft(text: "看 @a.m 好吗", picked: [a]).pruned
        XCTAssertTrue(MentionDraft(text: text, picked: pruned.picked).mentions.isEmpty)
    }

    func testRemovingAMentionTakesEveryAppearanceAndItsSpace() {
        let a = file("a.md")
        let b = file("b.md")
        var draft = MentionDraft(text: "看 @a.md 和 @b.md 和 \(a.token) 吧", picked: [a, b])
        draft.remove(a)
        XCTAssertEqual(draft.text, "看 和 @b.md 和 吧")
        XCTAssertEqual(draft.picked, [b])
    }

    func testTwoThingsWithOneNameGetTellingNames() throws {
        var draft = MentionDraft()
        draft.insert(file("docs/README.md", "README.md"))
        draft.text += "和 @"
        draft.insert(file("src/README.md", "README.md"))
        draft.insert(file("docs/README.md", "README.md"))
        XCTAssertEqual(draft.text, "@README.md 和 @src/README.md @README.md ", "同一个文件再选一次用同一个名字")
        XCTAssertEqual(draft.mentions.map(\.target), ["docs/README.md", "src/README.md"])

        let first = chat("周报")
        let second = chat("周报")
        var chats = MentionDraft()
        chats.insert(first)
        chats.insert(second)
        XCTAssertEqual(chats.text, "@周报 @周报 (2) ")
        XCTAssertEqual(ComposerMention.mentions(in: chats.tokenized).map(\.target), [first.target, second.target])
    }

    func testTheLongestNameWinsAndRawTokensStillCount() {
        let short = chat("周报")
        let long = chat("周报 草稿")
        let raw = file("x.md")
        let draft = MentionDraft(text: "看 @周报 草稿 和 @周报 和 \(raw.token)", picked: [short, long])
        XCTAssertEqual(draft.mentions, [long, short, raw])
        XCTAssertEqual(draft.tokenized, "看 \(long.token) 和 \(short.token) 和 \(raw.token)")
        XCTAssertEqual(draft.pruned.picked, [short, long], "粘贴进来的完整 token 不进表，也不挤掉已选的")
    }

    func testTokensGoingBackIntoADraftNeverRunIntoTheirNeighbours() {
        let a = file("a.md")
        var draft = MentionDraft(text: "草稿")
        draft.appendTokenized("再看\(a.token)和\(skill.token)\(a.token)x", separator: "\n")
        XCTAssertEqual(draft.text, "草稿\n再看@a.md和$review @a.md x")
        XCTAssertEqual(draft.mentions, [a, skill])
        XCTAssertEqual(ComposerMention.mentions(in: draft.tokenized), [a, skill])

        // The text persists inside a queued message and comes back intact.
        let queued = QueuedMessage(text: draft.tokenized)
        let decoded = try? JSONDecoder().decode(QueuedMessage.self, from: JSONEncoder().encode(queued))
        XCTAssertEqual(decoded.map { MentionDraft(tokenized: $0.text) }, MentionDraft(tokenized: draft.tokenized))
    }

    func testPlainTextIsNeverReadAsAMention() {
        let id = UUID().uuidString
        let texts = [
            "@readme.md", "$review", "a@b.com", "[x](https://a.b)", "[@x](https://a.b)", "[@x](file:///etc/passwd)",
            "[$x](skill:relative/SKILL.md)", "[$x](skill:/abs/README.md)", "[@x](chat:not-a-uuid)", "[$x](file:a.md)",
            "[@x](skill:/a/SKILL.md)", "\\[@x](file:a.md)", "[@x](file:a b.md)", "[@](file:a.md)", "[@x](file:)",
            "[@x](mailto:\(id))", "[@x\n](file:a.md)", "[@x](tab:\(id)",
        ]
        for text in texts {
            XCTAssertTrue(ComposerMention.mentions(in: text).isEmpty, text)
            XCTAssertEqual(ComposerMention.readable(text), text, text)
        }
    }

    func testMentionsAreListedOnceInOrder() {
        let a = file("a.md")
        let b = file("b.md")
        XCTAssertEqual(ComposerMention.mentions(in: "\(b.token) \(a.token) \(b.token)"), [b, a])
    }

    // MARK: Files

    func testAFileInTheWorkingDirectoryIsAttachedWithItsText() throws {
        try write("docs/说明.md", "第一行\n第二行")
        let resolution = resolve([file("docs/说明.md")])
        XCTAssertEqual(resolution.notes, [])
        let block = try XCTUnwrap(resolution.blocks.first)
        XCTAssertFalse(block.truncated)
        XCTAssertEqual(block.text, "\n\n提及的文件 `docs/说明.md`：\n```md\n第一行\n第二行\n```")
    }

    func testAFileOverItsCapIsCutBetweenCharactersWithANote() throws {
        try write("big.txt", "一二三四五") // 15 bytes
        let resolution = resolve([file("big.txt")], limits: MentionLimits(fileBytes: 10))
        let block = try XCTUnwrap(resolution.blocks.first)
        XCTAssertTrue(block.truncated)
        XCTAssertTrue(block.text.contains("\n一二三\n"), "截在字符边界上，不当成二进制")
        XCTAssertEqual(resolution.notes, ["文件 big.txt 共 1 KB，只附上了前 1 KB。"])
    }

    func testABinaryFileIsRefusedWithANote() throws {
        try write("image.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
        try write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9])) // "café" in Latin-1
        let resolution = resolve([file("image.png"), file("latin1.txt")])
        XCTAssertTrue(resolution.blocks.isEmpty)
        XCTAssertEqual(resolution.notes, [
            "文件 image.png 不是 UTF-8 文本（可能是二进制文件），没有附上。",
            "文件 latin1.txt 不是 UTF-8 文本（可能是二进制文件），没有附上。",
        ])
    }

    func testFilesOutsideTheWorkingDirectoryNeedAnAbsolutePick() throws {
        let project = root.appendingPathComponent("project")
        try write("project/inside.md", "里面")
        try write("secret.txt", "外面的秘密")
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("secret.txt")
        )
        let outside = root.appendingPathComponent("secret.txt").path
        let refused = MentionResolver.resolve(
            [file("../secret.txt"), file("link.txt"), file(outside)],
            sources: MentionSources(workingDirectory: project.path, home: "/nonexistent-home")
        )
        XCTAssertTrue(refused.blocks.isEmpty)
        XCTAssertEqual(refused.notes, [
            "文件 ../secret.txt 在工作目录之外，没有附上。",
            "文件 link.txt 在工作目录之外，没有附上。",
            "文件 \(outside) 不在工作目录里，只有从列表里选取的文件才会附上。",
        ])

        let picked = MentionResolver.resolve(
            [file(outside), file(project.appendingPathComponent("inside.md").path)],
            sources: MentionSources(workingDirectory: project.path, home: "/nonexistent-home", pickedTargets: [outside])
        )
        XCTAssertEqual(picked.notes, [])
        XCTAssertEqual(picked.blocks.count, 2, "选取的绝对路径和工作目录里的绝对路径都附上")
        XCTAssertTrue(picked.blocks[0].text.contains("外面的秘密"))
    }

    func testARelativeFileWithoutAWorkingDirectoryIsRefused() {
        let resolution = MentionResolver.resolve([file("a.md")], sources: MentionSources(workingDirectory: nil, home: "/nonexistent-home"))
        XCTAssertEqual(resolution.notes, ["这个对话没有工作目录，文件 a.md 没有附上。"])
    }

    func testTheFenceOutgrowsBackticksInTheContent() throws {
        try write("notes.md", "示例：\n```swift\nlet a = 1\n```")
        let block = try XCTUnwrap(resolve([file("notes.md")]).blocks.first)
        XCTAssertTrue(block.text.hasSuffix("\n````"))
        XCTAssertTrue(block.text.contains("：\n````md\n示例"))
    }

    // MARK: Chats, tabs, skills

    func testAChatQuotesItsLatestMessagesWithinItsCap() throws {
        let id = UUID()
        let messages = ["一", "答一", "二", "答二", "三"].enumerated().map { index, text in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, parts: [.text(text)])
        } + [ChatMessage(role: .tool, parts: [.text("工具输出")])]
        let mention = try XCTUnwrap(ComposerMention(kind: .chat, label: "旧对话", target: id.uuidString))
        let sources = MentionSources(workingDirectory: nil, home: "/h", chats: [id: .init(title: "旧对话", messages: messages)])

        let latest = MentionResolver.resolve([mention], sources: sources, limits: MentionLimits(chatMessages: 3))
        XCTAssertEqual(latest.blocks.first?.text, "\n\n提及的对话「旧对话」（最近 3 条消息）：\n```\n用户：二\n助手：答二\n用户：三\n```")

        // 「助手：答二」 is 15 bytes, 「用户：三」 12; 20 bytes keep only the newest.
        let capped = MentionResolver.resolve([mention], sources: sources, limits: MentionLimits(chatBytes: 20))
        XCTAssertEqual(capped.blocks.first?.text, "\n\n提及的对话「旧对话」（最近 1 条消息）：\n```\n用户：三\n```")
        XCTAssertEqual(capped.notes, ["对话「旧对话」超过 1 KB，只附上了最近的内容。"])
    }

    func testALockedChatIsRefused() throws {
        let id = UUID()
        let mention = try XCTUnwrap(ComposerMention(kind: .chat, label: "私密", target: id.uuidString))
        let resolution = MentionResolver.resolve([mention], sources: MentionSources(
            workingDirectory: nil, home: "/h", chats: [id: .init(title: "私密", messages: [], isLocked: true)]
        ))
        XCTAssertEqual(resolution.notes, ["对话「私密」已锁定，没有附上。"])
        XCTAssertTrue(resolution.blocks.isEmpty)
    }

    func testATabSendsItsPageTextOrSaysThePageIsNotOpen() throws {
        let open = UUID()
        let closed = UUID()
        let openMention = try XCTUnwrap(ComposerMention(kind: .tab, label: "文档", target: open.uuidString))
        let closedMention = try XCTUnwrap(ComposerMention(kind: .tab, label: "首页", target: closed.uuidString))
        let sources = MentionSources(workingDirectory: nil, home: "/h", tabs: [
            open: .init(title: "文档", url: "https://a.test/doc", pageText: "  正文第一段\n正文第二段  "),
            closed: .init(title: "首页", url: "https://a.test", pageText: nil),
        ])
        let resolution = MentionResolver.resolve([openMention, closedMention], sources: sources)
        XCTAssertEqual(resolution.blocks.map(\.text), [
            "\n\n提及的标签页「文档」：\n```\n地址：https://a.test/doc\n\n正文第一段\n正文第二段\n```",
            "\n\n提及的标签页「首页」：\n```\n地址：https://a.test\n```",
        ])
        XCTAssertEqual(resolution.notes, ["标签页「首页」的页面没有在浏览器面板里打开，只附上了标题和地址。"])

        let capped = MentionResolver.resolve([openMention], sources: sources, limits: MentionLimits(tabBytes: 30))
        XCTAssertEqual(capped.blocks.first?.truncated, true)
        XCTAssertEqual(capped.notes, ["标签页「文档」的页面文字超过 1 KB，只附上了开头。"])
    }

    func testASkillSendsItsSKILLmdAsAnExplicitInvocation() throws {
        try write(".agents/skills/review/SKILL.md", "---\nname: review\ndescription: 审查代码\n---\n按清单逐项审查。")
        let path = root.appendingPathComponent(".agents/skills/review/SKILL.md").path
        let skill = try SkillCatalog.parse(path: path, scope: .repository)
        let mention = try XCTUnwrap(ComposerMention(kind: .skill, label: "review", target: path))
        let resolution = MentionResolver.resolve([mention], sources: MentionSources(workingDirectory: root.path, home: "/h", skills: [skill]))
        let text = try XCTUnwrap(resolution.blocks.first?.text)
        XCTAssertTrue(text.hasPrefix("\n\n用户在这条消息里用 $review 显式调用了技能「review」（项目，\(path)）。"))
        XCTAssertTrue(text.hasSuffix("```markdown\n---\nname: review\ndescription: 审查代码\n---\n按清单逐项审查。\n```"))

        let capped = MentionResolver.resolve([mention], sources: MentionSources(workingDirectory: root.path, home: "/h", skills: [skill]),
                                            limits: MentionLimits(skillBytes: 8))
        XCTAssertEqual(capped.blocks.first?.truncated, true)
        XCTAssertEqual(capped.notes.count, 1)
        XCTAssertTrue(capped.notes[0].hasPrefix("技能 $review 的 SKILL.md 共 1 KB，只附上了前 1 KB"))
    }

    func testVanishedTargetsBecomeNotesNotErrors() throws {
        let gone = [
            file("deleted.md"),
            try XCTUnwrap(ComposerMention(kind: .chat, label: "删掉的对话", target: UUID().uuidString)),
            try XCTUnwrap(ComposerMention(kind: .tab, label: "关掉的页", target: UUID().uuidString)),
            try XCTUnwrap(ComposerMention(kind: .skill, label: "old", target: "/gone/old/SKILL.md")),
        ]
        let resolution = resolve(gone)
        XCTAssertTrue(resolution.blocks.isEmpty)
        XCTAssertEqual(resolution.notes, [
            "文件 deleted.md 已不存在，没有附上。",
            "对话「删掉的对话」已不存在，没有附上。",
            "标签页「关掉的页」已关闭，没有附上。",
            "技能 $old 已不存在，没有附上。",
        ])
        XCTAssertEqual(resolution.attachments.last?.text.hasPrefix("\n\n提及说明：\n- 文件 deleted.md 已不存在"), true)
        XCTAssertEqual(resolution.attachments.last?.notes.count, 4)
    }

    func testTheTotalCapCutsOneMentionAndDropsTheRestWithANote() throws {
        try write("a.txt", "aaaaaaaaaaaaaaa") // 15 bytes each
        try write("b.txt", "bbbbbbbbbbbbbbb")
        try write("c.txt", "ccccccccccccccc")
        let resolution = resolve([file("a.txt"), file("b.txt"), file("c.txt")], limits: MentionLimits(totalBytes: 20))
        XCTAssertEqual(resolution.blocks.count, 2)
        XCTAssertFalse(resolution.blocks[0].truncated)
        XCTAssertTrue(resolution.blocks[1].truncated)
        XCTAssertTrue(resolution.blocks[1].text.contains("\nbbbbb\n"), "剩下的 5 字节")
        XCTAssertEqual(resolution.notes, ["提及的内容合计超过 1 KB 上限：@b.txt 只附上了开头，@c.txt 没有附上。"])
    }

    // MARK: The message

    private let fileBlock = "\n\n提及的文件 `a.md`：\n```\nA\n```"
    private let gone = "文件 b.md 已不存在，没有附上。"

    private func sentMessage() -> ChatMessage {
        let mention = file("a.md")
        return QueuedMessage(text: "看 \(mention.token) 吧", pastes: ["粘贴"], mentions: [
            MentionAttachment(mention: mention, text: fileBlock, truncated: true), MentionAttachment(notes: [gone]),
        ]).message
    }

    func testAQueuedMessageSendsReadableTextThenPastesThenMentions() throws {
        let mention = file("a.md")
        let message = sentMessage()
        XCTAssertEqual(message.parts, [
            .text("看 @a.md 吧"), .text("\n\n```\n粘贴\n```"), .text(fileBlock), .text("\n\n提及说明：\n- \(gone)"),
        ], "模型读到的部分和以前一样：文字、粘贴、提及、说明")
        XCTAssertEqual(QueuedMessage(text: "看 \(mention.token) 吧").preview, "看 @a.md 吧")

        let phone = QueuedMessage(text: "看 \(mention.token) 吧", remote: true)
        XCTAssertEqual(phone.message.parts, [.text("看 \(mention.token) 吧")], "手机发的原样发出")
        XCTAssertEqual(phone.message.mentions, [])

        let old = #"{"id":"\#(UUID().uuidString)","text":"旧消息"}"#
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.mentions, [], "旧文档没有 mentions 字段照常解码")
    }

    func testASentMessageTellsWhatTheUserWroteFromWhatWasAttached() throws {
        let message = sentMessage()
        XCTAssertEqual(message.concatenatedText, "看 @a.md 吧\n\n```\n粘贴\n```" + fileBlock + "\n\n提及说明：\n- \(gone)", "模型读的全文不变")
        XCTAssertEqual(message.writtenText, "看 @a.md 吧\n\n```\n粘贴\n```")
        XCTAssertEqual(message.mentionAttachments, [MentionAttachment(mention: file("a.md"), text: fileBlock, truncated: true)])
        XCTAssertEqual(message.mentionNotes, [gone])
        XCTAssertEqual(message.quotedText, "看 @a.md 吧\n\n```\n粘贴\n```\n（这条消息附上了 @a.md 的内容）")

        let stored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(stored, message, "存进工作区再读出来，标记还在")
        XCTAssertEqual(stored.writtenText, message.writtenText)
    }

    func testMessagesWithoutTrustworthyMarksReadAsTheyAlwaysDid() throws {
        let id = UUID().uuidString
        let old = #"{"id":"\#(id)","role":"user","parts":[{"text":"看 @a.md"},{"text":"\n\n提及的文件"}]}"#
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.mentions, [])
        XCTAssertEqual(legacy.writtenText, legacy.concatenatedText, "旧消息照旧整段显示")

        let badTarget = #"{"id":"\#(id)","role":"user","parts":[{"text":"看"},{"text":"块"}],"mentions":[{"part":1,"byteCount":3,"mention":{"kind":"chat","label":"x","target":"nope"},"truncated":false,"notes":[]}]}"#
        let bad = try JSONDecoder().decode(ChatMessage.self, from: Data(badTarget.utf8))
        XCTAssertEqual(bad.mentions, [], "标记坏了只丢标记，消息照常打开")
        XCTAssertEqual(bad.writtenText, "看块")

        var rebuilt = sentMessage()
        rebuilt.parts[2] = .text("改过的内容")
        XCTAssertEqual(rebuilt.mentionAttachments, [], "部分变了，标记不再算数")
        XCTAssertTrue(rebuilt.writtenText.contains("改过的内容"))
        XCTAssertEqual(rebuilt.mentionNotes, [gone], "没变的说明照旧")

        var shortened = sentMessage()
        shortened.parts = [.text("只剩一段")]
        XCTAssertEqual(shortened.writtenText, "只剩一段")
        XCTAssertEqual(shortened.mentionNotes, [])
    }

    func testQuotingAThreadNamesItsAttachmentsWithoutTheirContent() throws {
        let message = sentMessage()
        let prompt = SideChatContext.systemPrompt(title: "主对话", goal: nil, transcript: [message])
        XCTAssertTrue(prompt.contains("用户：看 @a.md 吧"))
        XCTAssertTrue(prompt.contains("（这条消息附上了 @a.md 的内容）"))
        XCTAssertFalse(prompt.contains("提及的文件"), "旁聊不重复附上的文件")
        XCTAssertFalse(prompt.contains(gone))

        let id = UUID()
        let mention = try XCTUnwrap(ComposerMention(kind: .chat, label: "主对话", target: id.uuidString))
        let quoted = MentionResolver.resolve([mention], sources: MentionSources(
            workingDirectory: nil, home: "/h", chats: [id: .init(title: "主对话", messages: [message])]
        ))
        XCTAssertFalse(quoted.blocks[0].text.contains("提及的文件"), "提及一个对话时也不把它附过的文件再附一遍")
        XCTAssertTrue(quoted.blocks[0].text.contains("（这条消息附上了 @a.md 的内容）"))
    }
}
