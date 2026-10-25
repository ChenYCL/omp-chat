import XCTest

/// Regression coverage for the saved-Mac list (可控设备): the rows come from
/// `AppSettings.pairedDevices`, and swiping a row away must remove it from the
/// screen *and* from the persisted document.
///
/// The workspace is seeded through `OMPCHAT_STORE_DIR`; no Mac relay is needed.
final class DevicesUITests: XCTestCase {
    private var storeURL: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devices-ui-\(UUID().uuidString)", isDirectory: true)
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

    func testSwipeForgetRemovesTheDeviceFromScreenAndDocument() throws {
        openDevices()
        let studio = app.staticTexts["书房 Mac"]
        let office = app.staticTexts["公司 Mac"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5), "应列出预置的两台 Mac")
        XCTAssertTrue(office.exists)

        studio.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "左滑应出现删除按钮")
        delete.tap()

        XCTAssertFalse(app.staticTexts["书房 Mac"].waitForExistence(timeout: 2), "被忘记的设备应从列表消失")
        XCTAssertTrue(app.staticTexts["公司 Mac"].exists, "另一台不应受影响")

        // The save runs asynchronously after the swipe.
        let saved = try waitForDocument(timeout: 5) { names in names == ["公司 Mac"] }
        XCTAssertEqual(saved, ["公司 Mac"], "落盘的 workspace.json 应只剩一台设备")
    }

    func testUnreachableDevicesAreMarkedOfflineWithAReason() {
        openDevices()
        XCTAssertTrue(app.staticTexts["书房 Mac"].waitForExistence(timeout: 5))
        let offline = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '离线 · '"))
        let deadline = Date().addingTimeInterval(10)
        while offline.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(offline.count, 2, "两台都连不上，应各自显示离线原因")
        XCTAssertFalse(app.staticTexts["已连接"].exists, "没有配对时不应出现「已连接」")
    }

    func testForgettingTheLastDeviceShowsTheEmptyState() throws {
        openDevices()
        for name in ["书房 Mac", "公司 Mac"] {
            let row = app.staticTexts[name]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.swipeLeft()
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            delete.tap()
        }
        XCTAssertTrue(app.staticTexts["还没有配对的设备"].waitForExistence(timeout: 3))
    }

    // MARK: - Helpers

    private func openDevices() {
        // A fresh workspace may open Settings first; dismiss it.
        let done = app.buttons["完成"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        let drawer = app.buttons["shell.drawer"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 8))
        drawer.tap()
        let item = app.staticTexts["设备"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// Polls workspace.json until `predicate` holds for the device names.
    private func waitForDocument(timeout: TimeInterval, _ predicate: ([String]) -> Bool) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var names: [String] = []
        repeat {
            let data = try Data(contentsOf: storeURL.appendingPathComponent("workspace.json"))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let settings = root["settings"] as? [String: Any]
            let devices = settings?["pairedDevices"] as? [[String: Any]] ?? []
            names = devices.compactMap { $0["name"] as? String }
            if predicate(names) { return names }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return names
    }

    private func seed() throws {
        let providerID = "11111111-1111-1111-1111-111111111111"
        // Ports 9 and 10 refuse connections at once, so the reachability probe
        // gives a deterministic "offline" without waiting for a timeout.
        func device(_ name: String, _ port: Int, _ stamp: String) -> [String: Any] {
            ["id": UUID().uuidString, "name": name, "transport": "lan", "host": "127.0.0.1", "port": port,
             "token": "", "hubURL": "", "roomCode": "", "lastConnectedAt": stamp]
        }
        let workspace: [String: Any] = [
            "conversations": [], "models": [], "projects": [],
            "providers": [[
                "baseURL": "http://127.0.0.1:9", "chatPath": "/v1/chat/completions",
                "createdAt": "2026-10-25T11:00:00Z", "extraHeaders": [:], "id": providerID,
                "isDefault": true, "kind": "openAICompatible", "modelsPath": "/v1/models", "name": "seed",
            ]],
            "settings": [
                "defaultModelID": "m", "defaultProviderID": providerID, "version": 1,
                "pairedDevices": [
                    device("书房 Mac", 9, "2026-10-25T12:00:00Z"),
                    device("公司 Mac", 10, "2026-10-24T12:00:00Z"),
                ],
            ],
            "version": 1,
        ]
        try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted])
            .write(to: storeURL.appendingPathComponent("workspace.json"))
        // A placeholder key keeps the first-run Settings sheet from covering the UI.
        try JSONSerialization.data(withJSONObject: ["secrets": ["provider.\(providerID)": "test-key-not-used"]])
            .write(to: storeURL.appendingPathComponent("secrets.json"))
    }
}
