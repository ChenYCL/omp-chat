import XCTest

/// Phone composer mention parity: typing `@` lists the other conversations,
/// tapping a row picks it (chip appears), and sending routes through
/// `model.send()` so the transcript keeps the readable `@名称` form while the
/// request carries the token. A `$` list needs a skill, which is seeded as a
/// repository skill under the store directory the app reads.
///
/// The workspace is seeded through `OMPCHAT_STORE_DIR`; no network or Mac
/// pairing is involved.
final class PhoneMentionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    private static let otherChatTitle = "另一个项目会话"
    private static let skillName = "发布周报"
    private static let skillDirectory = "skills-demo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try seedStore()

        app = XCUIApplication()
        app.launchArguments = ["-ompui-testing", "1"]
        app.launchEnvironment["OMPCHAT_STORE_DIR"] = storeURL.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Cases

    func testChatMentionListPickAndSendKeepsReadableForm() throws {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "输入条必须存在")
        field.tap()
        field.typeText("@")

        // An empty query lists the other conversations at once.
        let list = app.otherElements["composer.mention.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "输入 @ 后应出现候选列表")
        let row = app.buttons["composer.mention.item.0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "候选列表应列出会话")
        XCTAssertEqual(row.label, Self.otherChatTitle, "候选行应是另一个会话的标题")

        // Refine the query: the chat section keeps matching, and the file
        // section stays empty — the seeded thread's working directory holds
        // no files, and a plain phone thread has none at all.
        field.typeText("另一个")
        let listBody = app.descendants(matching: .any)["composer.mention.list"].firstMatch
        XCTAssertTrue(listBody.staticTexts["对话"].firstMatch.waitForExistence(timeout: 5),
                      "会话命中时应显示 对话 分组")
        XCTAssertFalse(listBody.staticTexts["文件"].firstMatch.exists,
                       "工作目录没有文件时不应出现 文件 分组")
        XCTAssertEqual(app.buttons["composer.mention.item.0"].firstMatch.label, Self.otherChatTitle)

        app.buttons["composer.mention.item.0"].firstMatch.tap()

        // The pick replaces the query with the readable form and shows a chip.
        let chip = app.otherElements["composer.mention.chip.0"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "选中后应出现提及 chip")
        XCTAssertTrue((composerField.value as? String ?? "").contains(Self.otherChatTitle),
                      "输入框应显示可读的 \(Self.otherChatTitle)")

        app.buttons["composer.send"].firstMatch.tap()

        // The bubble keeps the readable form; the resolved context rides as a
        // chip under it (mention attachments), not inline text.
        let bubble = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "@" + Self.otherChatTitle)
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "发送后消息应保留 @名称 的可读形式")
        XCTAssertEqual((composerField.value as? String ?? ""), "", "发送后输入框应清空")
    }

    func testSkillMentionListsSeededSkillAndCloses() throws {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "输入条必须存在")
        field.tap()
        field.typeText("$" + Self.skillName.prefix(2))

        let row = app.buttons["composer.mention.item.0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "输入 $ 后应列出技能")
        XCTAssertEqual(row.label, Self.skillName, "技能候选应是种子技能的名字")

        row.tap()
        let chip = app.otherElements["composer.mention.chip.0"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "选中技能后应出现 chip")

        // Clear the draft, retype the trigger, then close the reopened list
        // with 关闭 — Escape has no keyboard equivalent here.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText("$" + Self.skillName.prefix(2))
        XCTAssertTrue(app.buttons["composer.mention.dismiss"].firstMatch.waitForExistence(timeout: 5),
                      "重打触发符后候选列表应再次出现")
        app.buttons["composer.mention.dismiss"].firstMatch.tap()
        XCTAssertFalse(app.buttons["composer.mention.dismiss"].firstMatch.waitForExistence(timeout: 2),
                       "关闭后候选列表应收起")
    }

    // MARK: - Helpers

    private var composerField: XCUIElement {
        let identified = app.textViews["composer.input"].firstMatch
        if identified.exists { return identified }
        let named = app.textFields["composer.input"].firstMatch
        if named.exists { return named }
        return app.textViews.firstMatch
    }

    /// Two conversations (the newest one opens at launch) and one repository
    /// skill: `skills-demo/.agents/skills/发布周报/SKILL.md` inside the store,
    /// bound to the selected thread through its workingDirectory.
    private func seedStore() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        let skillDirectory = storeURL.appendingPathComponent(Self.skillDirectory, isDirectory: true)
        let skillFile = skillDirectory
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(Self.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let skill = """
        ---
        name: \(Self.skillName)
        description: 汇总本周进展并生成周报
        ---
        把对话里的要点整理成一份周报。
        """
        try skill.write(to: skillFile, atomically: true, encoding: .utf8)

        let message: [String: Any] = [
            "alternativeVersions": [],
            "createdAt": "2026-10-25T12:00:00Z",
            "currentVersionIndex": 0,
            "id": UUID().uuidString,
            "parts": [["text": "上一条消息，用来做会话预览"]],
            "role": "user",
            "status": "complete",
        ]
        // Newest first: the app opens 当前会话 at launch, so the OTHER
        // conversation is the only one the mention list can offer.
        let current: [String: Any] = [
            "alternativeReplies": [],
            "createdAt": "2026-10-26T10:00:00Z",
            "hasUnread": false,
            "id": UUID().uuidString,
            "isArchived": false,
            "isLocked": false,
            "isPinned": false,
            "isTemporary": false,
            "messages": [],
            "providerID": providerID,
            "title": "当前会话",
            "updatedAt": "2026-10-26T12:00:00Z",
            "workingDirectory": skillDirectory.path,
        ]
        let other: [String: Any] = [
            "alternativeReplies": [],
            "createdAt": "2026-10-25T09:00:00Z",
            "hasUnread": false,
            "id": UUID().uuidString,
            "isArchived": false,
            "isLocked": false,
            "isPinned": false,
            "isTemporary": false,
            "messages": [message],
            "providerID": providerID,
            "title": Self.otherChatTitle,
            "updatedAt": "2026-10-25T12:00:00Z",
        ]
        let workspace: [String: Any] = [
            "conversations": [current, other],
            "models": [],
            "projects": [],
            "providers": [[
                "baseURL": "http://127.0.0.1:9",
                "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-25T08:00:00Z",
                "extraHeaders": [:],
                "id": providerID,
                "isDefault": true,
                "kind": "openAICompatible",
                "modelsPath": "/v1/models",
                "name": "seed",
            ]],
            "settings": [
                "defaultModelID": "seed-model",
                "defaultProviderID": providerID,
                "version": 1,
            ],
            "version": 1,
        ]
        try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("workspace.json"))
        try JSONSerialization.data(withJSONObject: ["secrets": ["provider.\(providerID)": "test-key-not-used"]])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
