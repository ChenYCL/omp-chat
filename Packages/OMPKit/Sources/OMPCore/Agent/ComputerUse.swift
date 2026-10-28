import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

// Computer use is not built into OMPChat: it is an open-source MCP server,
// pinned to one vetted release, that the user adds from 设置 → 电脑控制.
// Why these two servers, what they can do and what a bad update could do is
// in docs/computer-use.md; re-vet before changing a pinned version.

/// Whose macOS privacy grants a computer-use server acts under.
public enum ComputerUsePermissionHolder: String, Sendable, Hashable {
    /// The server is a bare executable OMPChat spawns, so macOS attributes
    /// its Accessibility and Screen Recording use to the responsible app,
    /// OMPChat.
    case hostApp
    /// The server relaunches itself as its own signed app through Launch
    /// Services, and the grants belong to that app, not to OMPChat.
    case ownApp
}

/// One vetted computer-use MCP server, pinned to an exact release.
public struct ComputerUseServer: Identifiable, Sendable, Hashable {
    /// Same as `config.id`.
    public var id: String { config.id }
    public let name: String
    /// What it does, in one or two plain sentences (中文).
    public let summary: String
    /// What it can do once added, one item per line (中文).
    public let capabilities: [String]
    /// Ready to store in `AppSettings.mcpServers`: pinned arguments,
    /// `risk: .control`, origin "catalog", and disabled until the user turns
    /// it on after reading the warning.
    public let config: MCPServerConfig
    /// npm package name and the exact version it is pinned to.
    public let package: String
    public let pinnedVersion: String
    /// The source commit the pinned release was built from.
    public let pinnedCommit: String
    /// What has to be installed for `config.command` to run (中文).
    public let requirement: String
    /// SPDX licence identifier.
    public let license: String
    public let homepage: URL
    public let permissionHolder: ComputerUsePermissionHolder
    /// Name of the app the grants belong to when `permissionHolder == .ownApp`.
    public let permissionAppName: String?
    /// Terminal command that opens the server's own permission onboarding,
    /// for an `.ownApp` server that does not ask while running as MCP.
    public let permissionSetupCommand: String?
    /// When the pinned release was last reviewed, `yyyy-MM-dd`.
    public let verifiedDate: String

    /// The pinned package spec as npx receives it, `name@x.y.z`.
    public var packageSpec: String { "\(package)@\(pinnedVersion)" }

    /// A config file holding just this server, in the `mcpServers` shape
    /// `MCPServerConfig.parse` reads (what the user would paste elsewhere).
    public func configJSON() -> Data {
        var entry: [String: Any] = ["args": config.args]
        if let command = config.command { entry["command"] = command }
        if let url = config.url { entry["url"] = url }
        if !config.env.isEmpty { entry["env"] = config.env }
        let object: [String: Any] = ["mcpServers": [config.id: entry]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

public enum ComputerUseCatalog {
    /// The primary pick first, then the fallback. Added only from the 电脑控制
    /// pane, never from the MCP catalog, so the warning cannot be skipped.
    public static let servers: [ComputerUseServer] = [dockerSandbox, openComputerUse, munimComputerUse]

    /// The Docker sandbox on the VPS (`tools/computer-use-docker/`): a
    /// throwaway Linux desktop the model controls over the SSH tunnel. It is
    /// the only entry that actually works from the sandboxed app (measured
    /// 2026-10-28, see docs/computer-use.md); the native ones cannot start
    /// here. Added as a Streamable-HTTP server pointing at the tunnel.
    public static let dockerSandbox = ComputerUseServer(
        name: "电脑控制沙盒（VPS Docker）",
        summary: "控制 netcup VPS 上 Docker 容器里的 Linux 桌面（Xvfb + GTK 应用），经 SSH 隧道连接，碰不到这台 Mac。",
        capabilities: [
            "列出容器里运行的应用和窗口，读取它们的界面结构",
            "在容器桌面里点击、拖拽、滚动、输入文字、按快捷键、改控件的值",
            "启动容器内的应用、切换窗口",
            "所有操作都只影响容器，不影响这台 Mac 的任何窗口",
        ],
        config: MCPServerConfig(
            id: "computer-use-sandbox", name: "电脑控制沙盒（VPS Docker）",
            command: "nc", args: ["127.0.0.1", "8766"],
            enabled: false, risk: .control, origin: "catalog"
        ),
        package: "@opensymph/open-computer-use（容器内）",
        pinnedVersion: "1.3.0",
        pinnedCommit: "e551c13e7082ce4c097234137582fbf4a1bc647a",
        requirement: "VPS 上的容器已启动（/opt/omp-computer-use），本机已开 SSH 隧道 127.0.0.1:8766",
        license: "MIT",
        homepage: URL(string: "https://github.com/opensymph/open-computer-use")!,
        permissionHolder: .hostApp,
        permissionAppName: nil,
        permissionSetupCommand: nil,
        verifiedDate: "2026-10-28"
    )

    /// opensymph/open-computer-use v1.3.0 (MIT). The npm tarball carries the
    /// Developer ID signed macOS runtime itself, so npm's integrity hash
    /// covers the native code; the postinstall script only prints help.
    public static let openComputerUse = ComputerUseServer(
        name: "Open Computer Use",
        summary: "通过辅助功能读取应用界面并截图，在后台点击、输入、滚动。⚠️ 在当前的 App Sandbox 下无法直接启动（原生可执行文件带隔离标记，启动即 spawn EPERM）；详见 docs/computer-use.md。推荐使用上方的电脑控制沙盒。",
        capabilities: [
            "列出正在运行的应用和窗口，读取它们的界面结构并截图",
            "截取整块屏幕（含菜单栏和程序坞）",
            "在任意应用里点击、拖拽、滚动、输入文字、按快捷键、改控件的值",
            "启动应用、把窗口切到前台",
        ],
        config: MCPServerConfig(
            id: "open-computer-use", name: "Open Computer Use",
            command: "npx", args: ["-y", "@opensymph/open-computer-use@1.3.0", "mcp"],
            enabled: false, risk: .control, origin: "catalog"
        ),
        package: "@opensymph/open-computer-use",
        pinnedVersion: "1.3.0",
        pinnedCommit: "e551c13e7082ce4c097234137582fbf4a1bc647a",
        requirement: "Node.js 18 或更高（npx）；macOS 14 或更高",
        license: "MIT",
        homepage: URL(string: "https://github.com/opensymph/open-computer-use")!,
        permissionHolder: .ownApp,
        permissionAppName: "Open Computer Use",
        // `mcp` mode never prompts; only `doctor` opens the onboarding window.
        permissionSetupCommand: "npx -y @opensymph/open-computer-use@1.3.0 doctor",
        verifiedDate: "2026-10-26"
    )

    /// munimtechnologies/munim-computer-use v0.7.3 (Apache-2.0). The npm
    /// launcher downloads the release binary from GitHub on first run, which
    /// it does not checksum; see docs/computer-use.md. The browser tools need
    /// a Chrome extension OMPChat does not install, so they are hidden.
    public static let munimComputerUse = ComputerUseServer(
        name: "Munim Computer Use",
        summary: "通过辅助功能读取应用界面，把点击和按键直接发给目标应用。⚠️ 在当前的 App Sandbox 下无法直接启动（下载的原生可执行文件无法在沙盒中执行）；详见 docs/computer-use.md。推荐使用上方的电脑控制沙盒。",
        capabilities: [
            "列出应用和显示器，读取应用界面结构，截取屏幕或放大截取一块区域",
            "在任意应用里点击、右键、悬停、拖拽、滚动、输入文字、按快捷键、选中文字、改控件的值",
            "读写剪贴板",
            "把应用切到前台",
        ],
        config: MCPServerConfig(
            id: "munim-computer-use", name: "Munim Computer Use",
            command: "npx", args: ["-y", "munim-computer-use@0.7.3"],
            env: ["COMPUTER_USE_BROWSER": "0"],
            enabled: false, risk: .control, origin: "catalog"
        ),
        package: "munim-computer-use",
        pinnedVersion: "0.7.3",
        pinnedCommit: "160509b9747db3f90d741eb5367574c942d2351b",
        requirement: "Node.js 18 或更高（npx）；首次运行从 GitHub 下载约 0.8 MB 的程序；macOS 14 或更高",
        license: "Apache-2.0",
        homepage: URL(string: "https://github.com/munimtechnologies/munim-computer-use")!,
        permissionHolder: .hostApp,
        permissionAppName: nil,
        // Its own `request-permissions` would grant the terminal, not OMPChat.
        permissionSetupCommand: nil,
        verifiedDate: "2026-10-26"
    )

    public static func server(id: String) -> ComputerUseServer? {
        servers.first { $0.id == id }
    }
}

/// Sorts a computer-use tool call for wording only ("查看" vs "操作").
/// Approval never depends on it: every tool of a computer-use server is
/// `ToolRisk.control`, observing included, because a screenshot of any app
/// goes to the model provider.
public enum ComputerUseClassifier {
    public enum Kind: String, Sendable, Equatable {
        /// Reads the screen, an app's interface, or the app and window lists.
        case observe
        /// Clicks, types, scrolls, launches or otherwise changes something.
        case act
        /// Neither, or a tool this table does not know.
        case other
    }

    /// Takes the server's own tool name, or an `mcp__<server>__<tool>` wire
    /// name.
    public static func kind(of toolName: String) -> Kind {
        let name = bareName(toolName)
        if observeTools.contains(name) { return .observe }
        if actTools.contains(name) { return .act }
        return .other
    }

    static func bareName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"),
              let separator = name.dropFirst(5).range(of: "__") else { return name }
        return String(name[separator.upperBound...])
    }

    // Tool names of the pinned releases of both catalog servers.
    private static let observeTools: Set<String> = [
        "list_apps", "get_app_state", "list_windows", "get_window", "get_window_state",
        "capture_display", "screenshot", "list_displays", "zoom", "clipboard_read",
        "browser_list_tabs", "browser_snapshot", "browser_read",
    ]
    private static let actTools: Set<String> = [
        "click", "right_click", "drag", "scroll", "hover", "type_text", "press_key",
        "set_value", "select_text", "perform_secondary_action", "launch_app",
        "activate_app", "activate_window", "clipboard_write",
        "browser_open_tab", "browser_use_tab", "browser_release_tab", "browser_select_tab",
        "browser_close_tab", "browser_close_all_tabs", "browser_navigate", "browser_click",
        "browser_type", "browser_press_key", "browser_request_credentials",
    ]
}

/// The two System Settings panes computer use needs.
public enum ComputerUsePrivacyPane: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility

    public var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    /// Opens 系统设置 → 隐私与安全性 at this pane.
    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

#if os(macOS)
/// What macOS has granted OMPChat itself.
///
/// These calls report on the calling process. A child process's Screen
/// Recording and Accessibility use is attributed to its responsible app, so
/// for a `.hostApp` server these are the grants that count; a `.ownApp`
/// server asks for its own grants under its own app name. Whether the
/// attribution holds for a server spawned by the sandboxed, installed
/// OMPChat build has to be checked on that build.
public enum ComputerUsePermissions {
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own Screen Recording prompt the first time; later calls
    /// return the current state without prompting. A new grant usually takes
    /// effect only after OMPChat relaunches.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func isGranted(_ pane: ComputerUsePrivacyPane) -> Bool {
        switch pane {
        case .screenRecording: screenRecordingGranted
        case .accessibility: accessibilityGranted
        }
    }

    public static func openSettings(_ pane: ComputerUsePrivacyPane) {
        NSWorkspace.shared.open(pane.settingsURL)
    }
}
#endif
