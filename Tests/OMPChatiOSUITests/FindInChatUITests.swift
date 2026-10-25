import XCTest

/// The phone's 在对话中查找 used to post a notification only the macOS detail
/// view listened to, so tapping it changed nothing. This drives the real bar.
final class FindInChatUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try seed()
        app = XCUIApplication()
        app.launchArguments = ["-ompui-testing", "1"]
        app.launchEnvironment["OMPCHAT_STORE_DIR"] = storeURL.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testFindBarOpensAndCountsHits() {
        XCTAssertTrue(app.descendants(matching: .any)["shell.title"].firstMatch.waitForExistence(timeout: 10),
                      "会话应已打开")
        // 在对话中查找 lives in the top-right overflow menu.
        app.buttons["shell.overflow"].firstMatch.tap()
        app.buttons["在对话中查找"].firstMatch.tap()

        let field = app.textFields["chat.find"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "应出现查找栏")
        field.tap()
        field.typeText("mermaid")
        let count = app.staticTexts["chat.find.count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "应显示命中数")
        XCTAssertEqual(count.label, "2 处", "两条消息包含 mermaid")

        // Walking hits changes the label to 1/2 and back, proving both buttons
        // reach the cursor logic.
        app.buttons["下一处"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1/2"].waitForExistence(timeout: 3), "下一处应走到第 1 处")
        app.buttons["下一处"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 3), "再点一次到第 2 处")
        app.buttons["上一处"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1/2"].waitForExistence(timeout: 3), "上一处应回到第 1 处")

        app.buttons["关闭查找"].firstMatch.tap()
        XCTAssertFalse(field.exists, "关闭后查找栏应收起")
    }

    // MARK: - Helpers

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        func message(_ role: String, _ text: String) -> [String: Any] {
            [
                "alternativeVersions": [],
                "createdAt": "2026-10-26T10:00:00Z",
                "currentVersionIndex": 0,
                "id": UUID().uuidString,
                "parts": [["text": text]],
                "role": role,
                "status": "complete",
            ]
        }
        let conversation: [String: Any] = [
            "alternativeReplies": [],
            "createdAt": "2026-10-26T09:59:00Z",
            "hasUnread": false,
            "id": UUID().uuidString,
            "isArchived": false,
            "isLocked": false,
            "isPinned": false,
            "isTemporary": false,
            "messages": [
                message("user", "用 mermaid 画个流程图"),
                message("assistant", "这是 mermaid 版本"),
                message("user", "谢谢"),
            ],
            "providerID": providerID,
            "title": "查找回归",
            "updatedAt": "2026-10-26T10:00:00Z",
        ]
        let workspace: [String: Any] = [
            "conversations": [conversation],
            "models": [],
            "projects": [],
            "providers": [[
                "baseURL": "http://127.0.0.1:9",
                "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-26T09:00:00Z",
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
        let secrets: [String: Any] = ["secrets": ["provider.\(providerID)": "test-key-not-used"]]
        try JSONSerialization.data(withJSONObject: secrets, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
