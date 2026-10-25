import XCTest

/// The phone's 项目 sheet could create and delete a project but not rename it,
/// and showed only a chat count — no way to see what was inside.
final class ProjectsSheetUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-projects-\(UUID().uuidString)", isDirectory: true)
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

    func testProjectShowsItsChatsAndCanBeRenamed() {
        app.buttons["shell.drawer"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '项目'")).firstMatch.tap()

        XCTAssertTrue(app.staticTexts["· 属于项目的会话"].waitForExistence(timeout: 5), "项目应列出里面的会话")

        app.staticTexts["备份项目"].firstMatch.press(forDuration: 1.0)
        app.buttons["重命名"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "应弹出重命名输入框")
        field.tap()
        // The field is prefilled with the current name, so clear it first.
        // Clear with backspaces. ⌘A through typeKey depends on the simulator's
        // hardware-keyboard state and failed once another test class had run,
        // and the context menu's localized item name varies by language.
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("改过的名字")
        app.alerts.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["改过的名字"].waitForExistence(timeout: 5), "重命名应生效")
        XCTAssertFalse(app.staticTexts["备份项目"].exists, "旧名字不该还在")
    }

    // MARK: - Helpers

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        let projectID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let conversation: [String: Any] = [
            "alternativeReplies": [], "createdAt": "2026-10-26T09:59:00Z",
            "hasUnread": false, "id": UUID().uuidString,
            "isArchived": false, "isLocked": false, "isPinned": false, "isTemporary": false,
            "messages": [[
                "alternativeVersions": [], "createdAt": "2026-10-26T10:00:00Z",
                "currentVersionIndex": 0, "id": UUID().uuidString,
                "parts": [["text": "项目里的内容"]], "role": "user", "status": "complete",
            ]],
            "projectID": projectID,
            "providerID": providerID, "title": "属于项目的会话",
            "updatedAt": "2026-10-26T10:00:00Z",
        ]
        let workspace: [String: Any] = [
            "conversations": [conversation],
            "models": [],
            "projects": [[
                "createdAt": "2026-10-26T09:00:00Z",
                "id": projectID,
                "isCustomSection": false,
                "name": "备份项目",
                "order": 0,
            ]],
            "providers": [[
                "baseURL": "http://127.0.0.1:9", "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-26T09:00:00Z", "extraHeaders": [:], "id": providerID,
                "isDefault": true, "kind": "openAICompatible", "modelsPath": "/v1/models", "name": "seed",
            ]],
            "settings": ["defaultModelID": "seed-model", "defaultProviderID": providerID, "version": 1],
            "version": 1,
        ]
        try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("workspace.json"))
        let secrets: [String: Any] = ["secrets": ["provider.\(providerID)": "test-key-not-used"]]
        try JSONSerialization.data(withJSONObject: secrets, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
