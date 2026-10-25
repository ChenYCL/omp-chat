import XCTest

/// The phone's settings form used to carry only a subset of the desktop's
/// sections; 个性化 / 通知 / 排序 / 数据控制 were unreachable there.
final class SettingsSectionsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ompchat-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-ompui-testing", "1"]
        app.launchEnvironment["OMPCHAT_STORE_DIR"] = storeURL.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try? FileManager.default.removeItem(at: storeURL)
    }

    func testPhoneSettingsShowsTheSharedSections() {
        app.buttons["shell.overflow"].firstMatch.tap()
        app.buttons["设置"].firstMatch.tap()

        // A Form only builds the rows near the viewport, so scroll while
        // looking for each heading instead of expecting them all at once.
        for title in ["个性化", "通知", "侧栏会话排序", "数据控制"] {
            var found = app.staticTexts[title].firstMatch.exists
            for _ in 0..<6 where !found {
                app.swipeUp()
                found = app.staticTexts[title].firstMatch.exists
            }
            XCTAssertTrue(found, "设置里应有「\(title)」")
        }
    }
}
