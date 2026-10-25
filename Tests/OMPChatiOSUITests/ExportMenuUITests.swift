import XCTest

/// The phone's overflow menu offers the same three formats as the desktop's
/// export menu; JSON is the one 导入 reads back, so its absence mattered.
final class ExportMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-export-\(UUID().uuidString)", isDirectory: true)
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

    func testOverflowMenuOffersAllThreeFormats() {
        XCTAssertTrue(app.descendants(matching: .any)["shell.title"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["shell.overflow"].firstMatch.tap()
        XCTAssertTrue(app.buttons["导出 JSON 备份"].firstMatch.waitForExistence(timeout: 5), "应能导出 JSON")
        XCTAssertTrue(app.buttons["导出 Markdown"].firstMatch.exists, "应能导出 Markdown")
        XCTAssertTrue(app.buttons["分享会话"].firstMatch.exists, "应能分享 HTML")
    }

    // MARK: - Helpers

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        let conversation: [String: Any] = [
            "alternativeReplies": [],
            "createdAt": "2026-10-26T09:59:00Z",
            "hasUnread": false,
            "id": UUID().uuidString,
            "isArchived": false,
            "isLocked": false,
            "isPinned": false,
            "isTemporary": false,
            "messages": [[
                "alternativeVersions": [], "createdAt": "2026-10-26T10:00:00Z",
                "currentVersionIndex": 0, "id": UUID().uuidString,
                "parts": [["text": "导出测试"]], "role": "user", "status": "complete",
            ]],
            "providerID": providerID,
            "title": "导出回归",
            "updatedAt": "2026-10-26T10:00:00Z",
        ]
        let workspace: [String: Any] = [
            "conversations": [conversation],
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
