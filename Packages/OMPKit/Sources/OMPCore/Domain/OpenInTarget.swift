import Foundation

/// An app a thread's folder or a mentioned file can be opened in: Codex's
/// header Open-in button (official `fileViewer.openInAnotherApp`) and the
/// file reference menu's 打开方式 (`markdown.fileReference.openWith`).
///
/// Only the catalog and the rules live here; detecting which apps are
/// installed and launching them is AppKit's (`OpenInMenu`).
public struct OpenInTarget: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case fileManager
        case terminal
        case editor
    }

    /// What to do with a path in this app.
    public enum Action: Equatable, Sendable {
        /// Show the folder's contents in a Finder window.
        case showFolder(String)
        /// Select the file in its Finder folder.
        case reveal(String)
        /// Hand the path to the app.
        case open(String)
    }

    /// Stable key, persisted as the last used target.
    public var id: String
    public var name: String
    /// Preferred first: Sublime Text 4 before 3.
    public var bundleIDs: [String]
    public var kind: Kind

    public init(id: String, name: String, bundleIDs: [String], kind: Kind) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.kind = kind
    }

    /// Every target in menu order. Finder, Terminal, iTerm2, VS Code, Cursor
    /// and Xcode ids were read from installed apps' Info.plist; Windsurf,
    /// Zed, Sublime Text and Nova are their published ids.
    public static let catalog: [OpenInTarget] = [
        OpenInTarget(id: "finder", name: "访达", bundleIDs: ["com.apple.finder"], kind: .fileManager),
        OpenInTarget(id: "terminal", name: "终端", bundleIDs: ["com.apple.Terminal"], kind: .terminal),
        OpenInTarget(id: "iterm2", name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"], kind: .terminal),
        OpenInTarget(id: "vscode", name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], kind: .editor),
        OpenInTarget(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], kind: .editor),
        OpenInTarget(id: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"], kind: .editor),
        OpenInTarget(id: "zed", name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"], kind: .editor),
        OpenInTarget(id: "xcode", name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], kind: .editor),
        OpenInTarget(id: "sublimeText", name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"], kind: .editor),
        OpenInTarget(id: "nova", name: "Nova", bundleIDs: ["com.panic.Nova"], kind: .editor),
    ]

    /// What opening `path` here means. A terminal is handed a file's folder:
    /// handed the file itself, Terminal runs it as a shell script. Finder
    /// shows a folder's contents and selects a file in its folder.
    public func action(for path: String, isDirectory: Bool) -> Action {
        switch kind {
        case .fileManager:
            return isDirectory ? .showFolder(path) : .reveal(path)
        case .terminal:
            return .open(isDirectory ? path : Self.parent(of: path))
        case .editor:
            return .open(path)
        }
    }

    /// The header's primary button: the last used target while it is still
    /// installed, otherwise the first installed one.
    public static func preferred(lastUsedID: String, installed: [OpenInTarget]) -> OpenInTarget? {
        installed.first { $0.id == lastUsedID } ?? installed.first
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
