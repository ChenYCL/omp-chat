import XCTest

/// Swiping the phone's title moves to the previous/next conversation, the
/// stand-in for the desktop's ⌥↑/⌥↓. Seeded through `OMPCHAT_STORE_DIR`, so no
/// network or Mac pairing is involved.
final class ConversationCycleUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-cycle-\(UUID().uuidString)", isDirectory: true)
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

    func testMenuMovesBetweenConversations() {
        // Newest first, so the app opens 第二个会话.
        XCTAssertTrue(app.staticTexts["第二个会话标题"].waitForExistence(timeout: 10), "启动应停在最新的会话")
        let title = app.descendants(matching: .any)["shell.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "标题应可定位")

        // The list is newest first, so the app opens at its top: 下一个对话 walks
        // down the sidebar to the older one, 上一个对话 comes back.
        title.tap()
        app.buttons["下一个对话"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["未读会话标题"].waitForExistence(timeout: 5), "下一个对话应走到侧栏里更早的那条")

        title.tap()
        app.buttons["上一个对话"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["第二个会话标题"].waitForExistence(timeout: 5), "上一个对话应回到更新的那条")
    }

    func testDrawerListsUnreadConversationUnderPendingWithoutDuplicatingIt() {
        app.buttons["shell.drawer"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["待处理"].waitForExistence(timeout: 5), "抽屉应有 待处理 分组")
        // 待处理 + 主列表各出现一次就会重复；标题只应有一处。
        let rows = app.staticTexts.matching(identifier: "未读会话标题")
        XCTAssertEqual(rows.count, 1, "未读会话只应在 待处理 里出现一次")
    }

    func testDrawerRowMenuPinsAndUnpins() {
        app.buttons["shell.drawer"].firstMatch.tap()
        let row = app.staticTexts["第二个会话标题"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Long-press opens the row's menu; 置顶 should become 取消置顶 after it runs.
        row.press(forDuration: 1.0)
        app.buttons["置顶"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "置顶后抽屉应仍在")

        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["取消置顶"].firstMatch.waitForExistence(timeout: 5), "置顶后菜单项应变成取消置顶")
    }

    // MARK: - Helpers

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        func message(_ role: String, _ text: String) -> [String: Any] {
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
        func unreadConversation(_ title: String, minute: Int) -> [String: Any] {
            var item = conversation(title, "未读的一条", minute: minute)
            item["hasUnread"] = true
            return item
        }

        func conversation(_ title: String, _ body: String, minute: Int) -> [String: Any] {
            [
                "alternativeReplies": [],
                "createdAt": "2026-10-25T11:0\(minute):00Z",
                "hasUnread": false,
                "id": UUID().uuidString,
                "isArchived": false,
                "isLocked": false,
                "isPinned": false,
                "isTemporary": false,
                "messages": [message("user", body), message("assistant", "好的")],
                "providerID": providerID,
                "title": title,
                "updatedAt": "2026-10-25T12:0\(minute):00Z",
            ]
        }
        let workspace: [String: Any] = [
            "conversations": [
                conversation("第一个会话标题", "第一段内容", minute: 0),
                unreadConversation("未读会话标题", minute: 3),
                conversation("第二个会话标题", "第二段内容", minute: 5),
            ],
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
        try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("workspace.json"))
        let secrets: [String: Any] = ["secrets": ["provider.\(providerID)": "test-key-not-used"]]
        try JSONSerialization.data(withJSONObject: secrets, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
