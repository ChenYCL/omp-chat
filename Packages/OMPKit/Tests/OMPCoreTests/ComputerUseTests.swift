import XCTest
@testable import OMPCore

final class ComputerUseTests: XCTestCase {
    // MARK: Catalog descriptors

    func testEveryServerIsPinnedToAnExactRelease() throws {
        let semver = try NSRegularExpression(pattern: #"^\d+\.\d+\.\d+$"#)
        for server in ComputerUseCatalog.servers {
            let version = server.pinnedVersion
            XCTAssertNotNil(
                semver.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)),
                "\(server.id): \(version) is not an exact version"
            )
            if server.config.command != nil {
                XCTAssertTrue(server.config.args.contains(server.packageSpec),
                              "\(server.id) does not run its pinned package spec")
                // A second, unpinned mention of the package would let npx pick
                // whatever is newest.
                let mentions = server.config.args.filter { $0.hasPrefix(server.package) }
                XCTAssertEqual(mentions, [server.packageSpec], server.id)
                for arg in server.config.args {
                    XCTAssertFalse(arg.lowercased().contains("latest"), "\(server.id): \(arg)")
                    XCTAssertFalse(arg.contains("@^") || arg.contains("@~") || arg.hasSuffix("@*"), "\(server.id): \(arg)")
                }
            }
            // The Docker sandbox entry has no local command: the pinned
            // release runs inside the container image, and the pin is checked
            // by the image build (tools/computer-use-docker/Dockerfile).
            XCTAssertEqual(server.pinnedCommit.count, 40, server.id)
            XCTAssertTrue(server.pinnedCommit.allSatisfy(\.isHexDigit), server.id)
        }
    }

    func testEveryServerIsControlRiskFromTheCatalogAndStartsDisabled() {
        XCTAssertEqual(ComputerUseCatalog.servers.count, 3)
        for server in ComputerUseCatalog.servers {
            XCTAssertEqual(server.config.risk, .control, server.id)
            XCTAssertEqual(server.config.origin, "catalog", server.id)
            XCTAssertFalse(server.config.enabled, server.id)
            XCTAssertEqual(MCPServerConfig.sanitizedID(server.id), server.id)
            XCTAssertEqual(server.homepage.scheme, "https", server.id)
            XCTAssertFalse(server.license.isEmpty, server.id)
        }
        XCTAssertEqual(Set(ComputerUseCatalog.servers.map(\.id)).count, ComputerUseCatalog.servers.count)
    }

    func testPermissionSetupCommandsRunThePinnedRelease() {
        for server in ComputerUseCatalog.servers {
            switch server.permissionHolder {
            case .ownApp:
                let words = (server.permissionSetupCommand ?? "").split(separator: " ").map(String.init)
                XCTAssertEqual(words.filter { $0.hasPrefix(server.package) }, [server.packageSpec], server.id)
                XCTAssertNotNil(server.permissionAppName, server.id)
            case .hostApp:
                // Run from a terminal, it would grant the terminal instead.
                // The Docker sandbox holds no local grants at all, so an empty
                // string is as good as nil there.
                XCTAssertTrue(server.permissionSetupCommand?.isEmpty ?? true, server.id)
            }
        }
    }

    func testTheDockerSandboxIsHTTPOnlyAndLocal() {
        let server = ComputerUseCatalog.dockerSandbox
        XCTAssertNil(server.config.command, "没有本地命令：真正的服务在容器里")
        XCTAssertEqual(server.config.url, "http://127.0.0.1:8766", "只指向本机隧道")
        XCTAssertEqual(server.permissionHolder, .hostApp)
        XCTAssertFalse(server.capabilities.isEmpty)
    }

    func testVerifiedDatesAreRealDates() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for server in ComputerUseCatalog.servers {
            XCTAssertNotNil(formatter.date(from: server.verifiedDate), server.id)
        }
    }

    func testConfigsParseBackThroughTheMCPConfigReader() throws {
        for server in ComputerUseCatalog.servers {
            let parsed = try MCPServerConfig.parse(server.configJSON(), origin: "catalog")
            XCTAssertTrue(parsed.skipped.isEmpty, "\(server.id): \(parsed.skipped)")
            let back = try XCTUnwrap(parsed.servers.first)
            XCTAssertEqual(parsed.servers.count, 1)
            XCTAssertEqual(back.id, server.config.id)
            XCTAssertEqual(back.command, server.config.command)
            XCTAssertEqual(back.args, server.config.args)
            XCTAssertEqual(back.env, server.config.env)
            XCTAssertEqual(back.url, server.config.url, server.id)
            XCTAssertEqual(back.origin, "catalog")
        }
    }

    func testLookupByID() {
        XCTAssertEqual(ComputerUseCatalog.server(id: "open-computer-use")?.name, "Open Computer Use")
        XCTAssertNil(ComputerUseCatalog.server(id: "playwright"))
    }

    // MARK: Classifier

    /// `ToolDefinitions.all` of open-computer-use v1.3.0.
    private let openComputerUseTools: [String: ComputerUseClassifier.Kind] = [
        "click": .act, "drag": .act, "get_app_state": .observe, "list_apps": .observe,
        "perform_secondary_action": .act, "press_key": .act, "scroll": .act,
        "set_value": .act, "type_text": .act, "list_windows": .observe,
        "get_window": .observe, "launch_app": .act, "get_window_state": .observe,
        "activate_window": .act, "capture_display": .observe,
    ]

    /// The macOS tool list of munim-computer-use v0.7.3.
    private let munimTools: [String: ComputerUseClassifier.Kind] = [
        "list_apps": .observe, "get_app_state": .observe, "click": .act, "type_text": .act,
        "press_key": .act, "scroll": .act, "activate_app": .act, "screenshot": .observe,
        "list_displays": .observe, "right_click": .act, "drag": .act, "set_value": .act,
        "zoom": .observe, "hover": .act, "wait": .other, "select_text": .act,
        "clipboard_read": .observe, "clipboard_write": .act,
        "browser_open_tab": .act, "browser_list_tabs": .observe, "browser_use_tab": .act,
        "browser_release_tab": .act, "browser_select_tab": .act, "browser_close_tab": .act,
        "browser_snapshot": .observe, "browser_read": .observe, "browser_click": .act,
        "browser_type": .act, "browser_request_credentials": .act, "browser_press_key": .act,
        "browser_close_all_tabs": .act, "browser_navigate": .act,
    ]

    func testClassifiesTheRealToolNamesOfBothServers() {
        XCTAssertEqual(munimTools.count, 32)
        for (name, expected) in openComputerUseTools.merging(munimTools, uniquingKeysWith: { a, _ in a }) {
            XCTAssertEqual(ComputerUseClassifier.kind(of: name), expected, name)
        }
    }

    func testClassifiesWireNamesByTheirToolPart() {
        XCTAssertEqual(ComputerUseClassifier.kind(of: "mcp__open-computer-use__click"), .act)
        XCTAssertEqual(ComputerUseClassifier.kind(of: "mcp__munim-computer-use__screenshot"), .observe)
        // A server whose id contains "__" still splits at the first separator.
        XCTAssertEqual(ComputerUseClassifier.kind(of: "mcp__a__get_app_state"), .observe)
    }

    func testUnknownNamesAreOther() {
        XCTAssertEqual(ComputerUseClassifier.kind(of: "delete_everything"), .other)
        XCTAssertEqual(ComputerUseClassifier.kind(of: ""), .other)
        XCTAssertEqual(ComputerUseClassifier.kind(of: "mcp__"), .other)
        XCTAssertEqual(ComputerUseClassifier.kind(of: "Click"), .other)
    }

    // MARK: System Settings links

    func testPrivacyDeepLinksOpenTheRightPanes() throws {
        let screen = ComputerUsePrivacyPane.screenRecording.settingsURL
        let access = ComputerUsePrivacyPane.accessibility.settingsURL
        for url in [screen, access] {
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "com.apple.preference.security")
        }
        XCTAssertEqual(URLComponents(url: screen, resolvingAgainstBaseURL: false)?.query, "Privacy_ScreenCapture")
        XCTAssertEqual(URLComponents(url: access, resolvingAgainstBaseURL: false)?.query, "Privacy_Accessibility")
    }
}
