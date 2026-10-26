#if os(macOS)
import AppKit

/// In-process screenshots of this app's own windows, behind the relay's
/// `GET /debug/windows` and `GET /debug/snapshot`.
///
/// It draws the window's view tree into a bitmap (`cacheDisplay`) instead of
/// reading pixels off the screen, so:
/// - the app does not need to be frontmost, and it works while other windows
///   cover it;
/// - only this app's windows can ever appear: there is no path to another app's
///   content, unlike a screen or desktop capture;
/// - no Screen Recording permission is involved.
///
/// Limits: standalone menus (`NSMenu`) are not windows in `NSApp.windows`, so a
/// menu that is open does not appear; popovers and sheets are listed as their
/// own windows.
@MainActor
public enum AppSnapshot {
    public struct WindowInfo: Codable, Equatable, Sendable {
        public var number: Int
        public var title: String
        /// "window", "sheet", "popover" or "panel".
        public var kind: String
        public var width: Int
        public var height: Int
        public var visible: Bool
        public var main: Bool
        public var key: Bool
    }

    private struct WindowList: Codable {
        var windows: [WindowInfo]
    }

    /// Every window of this app with a non-empty frame.
    public static func windows() -> [WindowInfo] {
        NSApp.windows
            .filter { $0.frame.width > 1 && $0.frame.height > 1 }
            .map(info)
    }

    public static func windowListJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(WindowList(windows: windows()))) ?? Data("{\"windows\":[]}".utf8)
    }

    /// PNG of the given window, or of the default window when `number` is nil.
    /// Nil when there is no such window or it cannot be drawn.
    public static func png(windowNumber number: Int?) -> Data? {
        let candidates = NSApp.windows
        let window: NSWindow?
        if let number {
            window = candidates.first { $0.windowNumber == number }
        } else {
            window = defaultWindow(in: candidates)
        }
        return window.flatMap(png(of:))
    }

    /// The window a bare `/debug/snapshot` means. `NSApp.mainWindow` is nil
    /// while the app is in the background, which is exactly when this is
    /// used, so fall back to the largest visible titled window.
    static func defaultWindow(in windows: [NSWindow]) -> NSWindow? {
        if let main = windows.first(where: { $0.isMainWindow && $0.isVisible }) { return main }
        return windows
            .filter { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Draws the window's frame view (title bar included) into a PNG at the
    /// window's backing scale.
    public static func png(of window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func info(_ window: NSWindow) -> WindowInfo {
        let kind: String
        if window.sheetParent != nil {
            kind = "sheet"
        } else if String(describing: type(of: window)).contains("Popover") {
            kind = "popover"
        } else if window is NSPanel {
            kind = "panel"
        } else {
            kind = "window"
        }
        return WindowInfo(
            number: window.windowNumber,
            title: window.title,
            kind: kind,
            width: Int(window.frame.width),
            height: Int(window.frame.height),
            visible: window.isVisible,
            main: window.isMainWindow,
            key: window.isKeyWindow
        )
    }
}
#endif
