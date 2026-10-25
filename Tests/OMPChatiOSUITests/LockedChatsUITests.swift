import XCTest

/// Locked chats are hidden from Recents and search. The phone's 已锁定 screen
/// asks for authentication first; without a passcode on the simulator it says
/// so instead of showing an empty list.
final class LockedChatsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-lock-\(UUID().uuidString)", isDirectory: true)
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

    func testLockedScreenGatesContent() {
        app.buttons["shell.drawer"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["锁定的会话"].exists, "锁定的会话不该出现在最近里")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已锁定'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已锁定"].waitForExistence(timeout: 5), "应显示锁定页")
        XCTAssertTrue(app.buttons["验证并解锁"].waitForExistence(timeout: 5), "解锁前应要求验证")
        // The private title must not be on screen before authentication.
        XCTAssertFalse(app.staticTexts["锁定的会话"].exists, "没解锁不应看到私密标题")
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
        func conversation(_ title: String, locked: Bool) -> [String: Any] {
            [
                "alternativeReplies": [], "createdAt": "2026-10-26T09:59:00Z",
                "hasUnread": false, "id": UUID().uuidString,
                "isArchived": false, "isLocked": locked, "isPinned": false, "isTemporary": false,
                "messages": [message(title)],
                "providerID": providerID, "title": title,
                "updatedAt": "2026-10-26T10:00:00Z",
            ]
        }
        let workspace: [String: Any] = [
            "conversations": [conversation("活跃的会话", locked: false), conversation("锁定的会话", locked: true)],
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
