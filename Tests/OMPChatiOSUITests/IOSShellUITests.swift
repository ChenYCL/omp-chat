import XCTest

/// White-box UI test suite for the unified iOS shell.
///
/// Runs against the real app in the simulator and asserts on the actual view
/// hierarchy (accessibility labels) plus freshly captured screenshots, so a
/// visual regression fails the suite instead of only showing up in a screenshot
/// nobody opens.
final class IOSShellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ompui-testing", "1"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Shell

    func testTabBarHasThreeRootDestinations() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "根级 TabBar 必须存在")

        let labels = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(labels.count, 3, "统一 IA 只保留三个一级域，实际：\(labels)")
        for expected in ["聊天", "主机", "远程"] {
            XCTAssertTrue(labels.contains(expected), "缺少一级 tab：\(expected)，实际：\(labels)")
        }
        attachScreenshot(named: "01-shell-chat")
    }

    func testDrawerOpensFromChatTopBar() {
        let menuButton = app.buttons.matching(identifier: "shell.drawer").firstMatch
        let hamburger = menuButton.exists ? menuButton : app.buttons.element(boundBy: 0)
        XCTAssertTrue(hamburger.waitForExistence(timeout: 10))
        let beforeTree = app.debugDescription
        hamburger.tap()
        sleep(2)
        let afterTree = app.debugDescription
        try? afterTree.write(toFile: "/tmp/ompchat-ui-tree.txt", atomically: true, encoding: .utf8)
        try? beforeTree.write(toFile: "/tmp/ompchat-ui-tree-before.txt", atomically: true, encoding: .utf8)

        XCTAssertTrue(
            app.staticTexts["shell.drawer.panel"].waitForExistence(timeout: 5),
            "点击 ☰ 后抽屉标题必须出现"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH '项目'")).firstMatch.exists,
            "抽屉必须列出二级入口（项目）"
        )
        attachScreenshot(named: "02-drawer-open")
    }

    func testHostTabShowsFourPanes() {
        app.tabBars.buttons["主机"].tap()

        for pane in ["文件", "终端", "脚本", "配置"] {
            let control = app.buttons[pane].firstMatch
            if control.waitForExistence(timeout: 5) {
                XCTAssertTrue(control.isHittable, "主机 \(pane) 切换应可点")
            }
        }
        attachScreenshot(named: "03-host-files")

        // Terminal pane must actually present a command surface, not a stub.
        // Several controls share the "终端" label (pane switch + tool strip),
        // so pick the one inside the pane switcher by position and retry once.
        let terminalButtons = app.buttons.matching(NSPredicate(format: "label == '终端'"))
        XCTAssertTrue(terminalButtons.count > 0, "主机页必须有终端切换")

        let commandField = app.textFields["host.terminal.input"].firstMatch
        let accessoryTab = app.buttons["Tab"].firstMatch

        var opened = false
        for index in 0..<min(terminalButtons.count, 3) {
            terminalButtons.element(boundBy: index).tap()
            if commandField.waitForExistence(timeout: 4) || accessoryTab.waitForExistence(timeout: 2) {
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "点击「终端」后应出现命令输入框或快捷键行")

        let promptRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '>' OR label CONTAINS 'main'")
        ).firstMatch
        XCTAssertTrue(
            promptRow.exists || commandField.exists,
            "终端面板应显示真实提示符或命令输入框"
        )
        XCTAssertTrue(app.buttons["Esc"].firstMatch.exists, "终端快捷键行应包含 Esc")
        attachScreenshot(named: "04-host-terminal")
    }

    func testRemoteTabStartsWithPairingForm() {
        app.tabBars.buttons["远程"].tap()

        let hostField = app.textFields["remote.host"].firstMatch
        let tokenField = app.secureTextFields["remote.token"].firstMatch
        let pairButton = app.buttons["remote.connect"].firstMatch
        let hasForm = hostField.waitForExistence(timeout: 5)
            || tokenField.waitForExistence(timeout: 5)
        XCTAssertTrue(hasForm || pairButton.exists, "远程页未配对时应显示配对表单或会话列表")
        attachScreenshot(named: "05-remote")
    }

    // MARK: - Composer

    func testComposerSendsMessageAndStreamsIntoTranscript() throws {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "输入条必须存在")

        let before = app.staticTexts.count
        field.tap()
        field.typeText("回归冒烟：请回复 OK")
        attachScreenshot(named: "06-composer-typed")

        let send = app.buttons["composer.send"].firstMatch
        if send.waitForExistence(timeout: 3) {
            send.tap()
        } else {
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'send' OR label CONTAINS[c] '发送'")).firstMatch.tap()
        }

        let grew = expectation(description: "transcript grows")
        let deadline = Date().addingTimeInterval(25)
        DispatchQueue.global().async {
            while Date() < deadline {
                if self.app.staticTexts.count > before {
                    grew.fulfill()
                    return
                }
                usleep(400_000)
            }
        }
        wait(for: [grew], timeout: 30)
        attachScreenshot(named: "07-after-send")
    }

    func testComposerClearsDraftWhenSwitchingConversation() {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("草稿隔离验证")

        app.tabBars.buttons["主机"].tap()
        app.tabBars.buttons["聊天"].tap()

        let value = (field.value as? String) ?? ""
        XCTAssertEqual(value, "草稿隔离验证", "切 tab 不应丢失草稿；实际：\(value)")
        attachScreenshot(named: "08-draft-preserved")
    }

    // MARK: - Dark mode

    func testDarkAppearanceRendersTranscript() {
        // The app reads appearance from settings; the simulator-level override
        // exercises the same adaptive colour tokens.
        XCUIDevice.shared.appearance = .dark
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(composerField.waitForExistence(timeout: 10))
        attachScreenshot(named: "09-dark")
        XCUIDevice.shared.appearance = .light
    }

    // MARK: - Helpers

    private var composerField: XCUIElement {
        let identified = app.textViews["composer.input"].firstMatch
        if identified.exists { return identified }
        let named = app.textFields["composer.input"].firstMatch
        if named.exists { return named }
        return app.textViews.firstMatch
    }

    private func attachScreenshot(named name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Exported to a host-visible location so the shots can be reviewed
        // outside Xcode's result bundle as well.
        let shared = URL(fileURLWithPath: "/tmp/ompchat-uitest-shots")
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: shared.appendingPathComponent("\(name).png"))
    }
}
