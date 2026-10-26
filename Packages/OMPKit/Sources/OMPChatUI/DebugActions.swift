#if os(macOS)
import AppKit
import OMPCore

/// Executes the token-gated `POST /debug/action` automation actions and
/// answers `GET /debug/state` for the macOS host.
///
/// Everything here must work while the app is in the background — that is the
/// whole point of the route: the integrator black-box tests the app without
/// bringing it to the front. Actions therefore go through the model and
/// NSApp's own action plumbing, never through synthetic clicks on windows.
///
/// Opening Settings programmatically: SwiftUI exposes the Settings scene to
/// the environment action `openSettings`, which only views can call. The same
/// behaviour is reachable from anywhere on macOS 13+ through the scene's menu
/// action: `NSApp.sendAction(to:)` with `showSettingsWindow:` (macOS 14+,
/// `showPreferencesWindow:` on older systems). Sending it to `nil` lets the
/// responder chain deliver it to the Settings scene exactly like the app menu's
/// 设置… item does, which does open the window even while the app is
/// backgrounded. Closing finds the Settings window by its SwiftUI-assigned
/// identifier and closes it with `performClose`.
@MainActor
enum DebugActions {
    /// Runs one action and reports success or a short error.
    static func perform(_ action: DebugAction, model: ChatAppModel) -> DebugActionOutcome {
        switch action {
        case .select(let conversationID):
            guard let id = UUID(uuidString: conversationID),
                  model.conversations.contains(where: { $0.id == id }) else {
                return .failure("no such conversation")
            }
            model.selectedConversationID = id
            return .success

        case .newChat:
            _ = model.newConversation()
            return .success

        case .sidePanel(let open, let tab):
            model.toggleSidePanel(open: open, tab: tab)
            return .success

        case .openSettings:
            return openSettings()

        case .closeSettings:
            return closeSettings()
        }
    }

    /// Serialized app state for the integrator: what the model selected and
    /// which of the app's own windows exist (title only, no pixels).
    static func stateJSON(model: ChatAppModel) -> Data {
        struct State: Encodable {
            var selectedID: String?
            var sidePanelOpen: Bool
            var sidePanelTab: String?
            var settingsOpen: Bool
            var windowTitles: [String]
        }
        let windows = AppSnapshot.windows()
        let state = State(
            selectedID: model.selectedConversationID?.uuidString,
            sidePanelOpen: model.sidePanelOpen,
            sidePanelTab: model.sidePanelOpen ? model.sidePanelTab.rawValue : nil,
            settingsOpen: settingsWindow() != nil,
            windowTitles: windows.map(\.title).filter { !$0.isEmpty }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)) ?? Data("{}".utf8)
    }

    // MARK: - Settings scene

    /// Opens the SwiftUI Settings scene through its menu action. Delivered
    /// via the responder chain to the scene, like the 设置… menu item.
    private static func openSettings() -> DebugActionOutcome {
        let settingsSelector = NSSelectorFromString("showSettingsWindow:")
        let legacySelector = NSSelectorFromString("showPreferencesWindow:")
        for selector in [settingsSelector, legacySelector] {
            guard NSApp.responds(to: selector) else { continue }
            if NSApp.sendAction(selector, to: nil, from: nil), settingsWindow() != nil {
                return .success
            }
        }
        return .failure("settings window did not open")
    }

    /// Closes the Settings scene's window. SwiftUI tags it with a fixed
    /// identifier, which is the only stable way to find it.
    private static func closeSettings() -> DebugActionOutcome {
        guard let window = settingsWindow() else { return .success }
        window.performClose(nil)
        return settingsWindow() == nil ? .success : .failure("settings window refused to close")
    }

    /// The Settings scene's window, by the identifier SwiftUI assigns it.
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }
    }
}
#endif
