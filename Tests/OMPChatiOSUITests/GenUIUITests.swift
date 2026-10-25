import XCTest

/// Regression coverage for `omp-ui` (generative UI): the block must render as
/// native SwiftUI, tabs must switch locally, and a button must post its text as
/// the next user turn.
///
/// The conversation is seeded through `OMPCHAT_STORE_DIR` (the app reads it for
/// both test and host runs), so no network or Mac pairing is involved.
final class GenUIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    private static let uiBlock = """
    ```omp-ui
    {"type":"tabs","id":"t","options":["总览","明细"],"style":"segmented"}
    {"type":"text","parent":"t","tab":"总览","text":"周报总览","style":"title"}
    {"type":"text","parent":"t","tab":"总览","text":"总览说明一行。"}
    {"type":"list","parent":"t","tab":"明细","items":["甲项","乙项","丙项"]}
    {"type":"button","label":"生成周报","send":"生成周报","style":"primary"}
    {"type":"input","id":"reason","label":"原因","placeholder":"写一句"}
    {"type":"slider","id":"days","label":"天数","min":1,"max":5,"value":2}
    {"type":"select","id":"level","options":["低","高"]}
    {"type":"button","label":"提交请假","send":"请假 {{days}} 天，原因：{{reason}}，级别：{{level}}"}
    ```
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genui-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try seed()

        app = XCUIApplication()
        app.launchEnvironment["OMPCHAT_STORE_DIR"] = storeURL.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Cases

    func testBlockRendersNativelyInsteadOfAsSource() {
        openSeededChat()

        XCTAssertTrue(app.staticTexts["周报总览"].exists, "标题应作为原生文本渲染")
        XCTAssertTrue(app.buttons["总览"].exists, "分段控件应渲染为可点按钮")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'omp-ui'")).firstMatch.exists,
            "不该把代码块的围栏标记显示出来"
        )
        XCTAssertTrue(app.buttons["查看源码"].exists, "应提供源码切换入口")
        XCTAssertTrue(app.buttons["生成周报"].isHittable, "omp-ui 按钮必须可点（曾被行手势与状态胶囊遮住）")
    }

    func testSwitchingTabRevealsItsChildren() {
        openSeededChat()
        XCTAssertTrue(app.staticTexts["周报总览"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["甲项"].exists, "总览标签下不应出现明细的列表项")

        let detail = app.buttons["明细"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 3), "应有「明细」标签")
        detail.tap()

        XCTAssertTrue(app.staticTexts["甲项"].waitForExistence(timeout: 3), "切到明细后应显示列表项")
        XCTAssertFalse(app.staticTexts["周报总览"].exists, "明细标签下不应再显示总览的文字")
    }

    func testButtonPostsItsTextAsNextUserMessage() {
        openSeededChat()
        let button = app.buttons["生成周报"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "应有「生成周报」按钮")
        button.tap()

        // The text becomes the user's next turn. There is no provider configured
        // in the seeded workspace, so the turn may fail — what matters is that
        // the message was posted.
        // The tap turns the label into a user bubble; the empty provider then
        // surfaces its own error, which is outside this test's scope.
        let userBubbles = app.staticTexts.matching(NSPredicate(format: "label == '生成周报'"))
        XCTAssertGreaterThanOrEqual(userBubbles.count, 1, "点击后应把文本作为用户消息发出")
        let transcript = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            transcript.contains("生成周报"),
            "用户消息应出现在会话里，实际标签：\(transcript.prefix(12))"
        )
    }

    func testFormFieldsFillTheButtonTemplate() {
        openSeededChat()
        let reason = app.descendants(matching: .any)["genui.reason"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "应渲染输入框")
        reason.tap()
        reason.typeText("家里有事\n")
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "回车（完成）应收起键盘")

        let days = app.sliders["genui.days"].firstMatch
        XCTAssertTrue(days.exists, "应渲染滑块")
        XCTAssertEqual(days.value as? String, "2", "滑块初值取模型给的 value")
        days.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["5"].waitForExistence(timeout: 2), "拖到最右，读数应为 5")

        let high = app.buttons["genui.level.高"].firstMatch
        XCTAssertTrue(high.exists, "应渲染选择项")
        XCTAssertTrue(app.buttons["genui.level.低"].isSelected, "选择项默认取第一项")
        high.tap()
        XCTAssertTrue(high.isSelected, "点「高」后应选中高")

        app.buttons["提交请假"].firstMatch.tap()
        let expected = "请假 5 天，原因：家里有事，级别：高"
        XCTAssertTrue(
            app.staticTexts[expected].waitForExistence(timeout: 5),
            "按钮应把表单当前值填进模板后作为用户消息发出：\(expected)"
        )
    }

    // MARK: - Helpers

    /// The seeded conversation is already selected at launch, so the chat
    /// screen shows it without touching the drawer or the title menu (both of
    /// which are overlays that would sit on top of the transcript).
    private func openSeededChat() {
        // A fresh workspace without a usable key opens Settings on first launch;
        // dismiss it so the transcript is reachable.
        let done = app.buttons["完成"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(
            app.staticTexts["周报总览"].waitForExistence(timeout: 10),
            "预置会话应直接显示在聊天页"
        )
    }

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        let message = { (role: String, text: String) -> [String: Any] in
            [
                "alternativeVersions": [],
                "createdAt": "2026-10-25T12:00:00Z",
                "currentVersionIndex": 0,
                "id": UUID().uuidString,
                "parts": [["text": text]],
                "role": role,
                "status": "complete",
            ]
        }
        let conversation: [String: Any] = [
            "alternativeReplies": [],
            "createdAt": "2026-10-25T11:59:00Z",
            "hasUnread": false,
            "id": UUID().uuidString,
            "isArchived": false,
            "isLocked": false,
            "isPinned": false,
            "isTemporary": false,
            "messages": [
                message("user", "做一个两标签界面"),
                message("assistant", Self.uiBlock),
            ],
            "providerID": providerID,
            "title": "界面回归",
            "updatedAt": "2026-10-25T12:00:00Z",
        ]
        let workspace: [String: Any] = [
            "conversations": [conversation],
            "models": [],
            "projects": [],
            "providers": [[
                "baseURL": "http://127.0.0.1:9",
                "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-25T11:00:00Z",
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
        let data = try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
        try data.write(to: storeURL.appendingPathComponent("workspace.json"))

        // Without a key the app treats itself as un-configured and force-opens
        // Settings over the transcript, which makes every row unhittable. A
        // placeholder key is enough: nothing in these tests sends a request.
        let secrets: [String: Any] = ["secrets": ["provider.\(providerID)": "test-key-not-used"]]
        try JSONSerialization.data(withJSONObject: secrets, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
