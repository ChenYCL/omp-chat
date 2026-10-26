import XCTest

/// Phone side of two Codex features: the thread goal (设定目标 in the + menu,
/// the 目标 chip above the composer) and 待处理 → 全部标为已读 in the drawer.
/// Seeded through `OMPCHAT_STORE_DIR`; the assertions read the saved
/// workspace too, so a control that only changes the screen does not pass.
final class GoalAndUnreadUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-goal-\(UUID().uuidString)", isDirectory: true)
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

    func testGoalIsSetFromThePlusMenuAndCleared() throws {
        XCTAssertTrue(app.staticTexts["最新的会话"].waitForExistence(timeout: 10), "启动应停在最新的会话")
        XCTAssertFalse(app.buttons["composer.goal.chip"].exists, "没设目标时不显示目标条")

        app.buttons["composer.plus"].firstMatch.tap()
        tapMenuItem("设定目标")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "应弹出目标输入框")
        field.typeText("补齐协议文档")
        app.alerts.buttons["完成"].firstMatch.tap()

        let chip = app.buttons["composer.goal.chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "设定后输入框上方应出现目标条")
        XCTAssertEqual(chip.label, "目标：补齐协议文档")
        XCTAssertTrue(waitForGoal(of: "最新的会话", toBe: "补齐协议文档"), "目标应写进工作区，后续请求才会带上")

        // The chip reopens the editor seeded with the goal; 清除 removes it.
        chip.tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.textFields.firstMatch.value as? String, "补齐协议文档", "再次打开时带出原目标")
        app.alerts.buttons["清除"].firstMatch.tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "清除后目标条消失")
        XCTAssertTrue(waitForGoal(of: "最新的会话", toBe: nil), "清除也要落盘")
    }

    func testMarkAllReadEmptiesThePendingGroup() throws {
        app.buttons["shell.drawer"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["待处理"].waitForExistence(timeout: 5), "两条未读应在 待处理 里")
        let markAll = app.buttons["drawer.markAllRead"].firstMatch
        XCTAssertTrue(markAll.exists, "待处理 标题旁应有 全部标为已读")
        markAll.tap()

        XCTAssertTrue(app.staticTexts["待处理"].waitForNonExistence(timeout: 5), "只因未读而在 待处理 的会话应离开，分组随之隐藏")
        for title in ["未读甲", "未读乙"] {
            XCTAssertEqual(app.staticTexts.matching(identifier: title).count, 1, "\(title) 回到最近会话，只出现一次")
        }
        XCTAssertTrue(waitForUnread([]), "已读状态应落盘")
    }

    // MARK: - Helpers

    /// SwiftUI menus show their items as buttons or menu items depending on
    /// the presentation; accept either.
    private func tapMenuItem(_ label: String) {
        let button = app.buttons[label].firstMatch
        let item = app.menuItems[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5) || item.exists, "菜单里应有「\(label)」")
        (button.exists ? button : item).tap()
    }

    private func conversations() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: storeURL.appendingPathComponent("workspace.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["conversations"] as? [[String: Any]] ?? []
    }

    private func poll(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func waitForGoal(of title: String, toBe goal: String?) -> Bool {
        poll {
            guard let conversation = conversations().first(where: { $0["title"] as? String == title }) else { return false }
            return conversation["goal"] as? String == goal
        }
    }

    private func waitForUnread(_ titles: Set<String>) -> Bool {
        poll {
            let unread = conversations().filter { $0["hasUnread"] as? Bool == true }.compactMap { $0["title"] as? String }
            return Set(unread) == titles
        }
    }

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        func message(_ role: String, _ text: String) -> [String: Any] {
            [
                "alternativeVersions": [], "createdAt": "2026-10-26T12:00:00Z", "currentVersionIndex": 0,
                "id": UUID().uuidString, "parts": [["text": text]], "role": role, "status": "complete",
            ]
        }
        func conversation(_ title: String, minute: Int, unread: Bool) -> [String: Any] {
            [
                "alternativeReplies": [], "createdAt": "2026-10-26T11:0\(minute):00Z",
                "hasUnread": unread, "id": UUID().uuidString,
                "isArchived": false, "isLocked": false, "isPinned": false, "isTemporary": false,
                "messages": [message("user", "\(title) 的问题"), message("assistant", "好的")],
                "providerID": providerID, "title": title,
                "updatedAt": "2026-10-26T12:0\(minute):00Z",
            ]
        }
        let workspace: [String: Any] = [
            "conversations": [
                conversation("未读甲", minute: 1, unread: true),
                conversation("未读乙", minute: 2, unread: true),
                conversation("最新的会话", minute: 5, unread: false),
            ],
            "models": [],
            "projects": [],
            "providers": [[
                "baseURL": "http://127.0.0.1:9", "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-26T11:00:00Z", "extraHeaders": [:], "id": providerID,
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
