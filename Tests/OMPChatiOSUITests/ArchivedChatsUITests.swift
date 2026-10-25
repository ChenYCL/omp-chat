import XCTest

/// Archived chats are hidden from Recents, so the phone needs its own way in.
final class ArchivedChatsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-arch-\(UUID().uuidString)", isDirectory: true)
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

    func testArchivedChatIsListedAndRestorable() {
        app.buttons["shell.drawer"].firstMatch.tap()
        // The archived chat is not in Recents.
        XCTAssertFalse(app.staticTexts["已归档的会话"].exists, "归档的会话不该出现在最近里")

        // The row's label is "已归档, 1" (title plus badge), so match by prefix.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已归档'")).firstMatch.tap()
        let row = app.staticTexts["已归档的会话"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "已归档页应列出它")

        row.swipeLeft()
        app.buttons["取消归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["没有已归档的会话"].waitForExistence(timeout: 5), "取消归档后列表应为空")
    }

    // MARK: - Helpers

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        func message(_ text: String) -> [String: Any] {
            [
                "alternativeVersions": [], "createdAt": "2026-10-26T10:00:00Z",
                "currentVersionIndex": 0, "id": UUID().uuidString,
                "parts": [["text": text]], "role": "user", "status": "complete",
            ]
        }
        func conversation(_ title: String, archived: Bool) -> [String: Any] {
            [
                "alternativeReplies": [], "createdAt": "2026-10-26T09:59:00Z",
                "hasUnread": false, "id": UUID().uuidString,
                "isArchived": archived, "isLocked": false, "isPinned": false, "isTemporary": false,
                "messages": [message(title)],
                "providerID": providerID, "title": title,
                "updatedAt": "2026-10-26T10:00:00Z",
            ]
        }
        let workspace: [String: Any] = [
            "conversations": [conversation("活跃的会话", archived: false), conversation("已归档的会话", archived: true)],
            "models": [], "projects": [],
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
