#if os(macOS)
import AppKit
import SwiftUI
import OMPCore
import OMPDesign

/// Installed apps of `OpenInTarget.catalog`, found by bundle id through
/// Launch Services, and the AppKit side of opening a path in one.
///
/// A sandboxed app may hand files it can read to another app through
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` and Finder's
/// reveal; neither needs the Apple Events entitlement, and this app reads
/// all of `/` (`temporary-exception.files.absolute-path.read-write`).
enum OpenInApps {
    struct Installed: Identifiable {
        var target: OpenInTarget
        var url: URL
        /// The app's icon at menu size.
        var icon: NSImage
        var id: String { target.id }
    }

    /// Every catalog target with an installed app, in catalog order; the
    /// first installed bundle id of a target wins.
    static func installed() -> [Installed] {
        OpenInTarget.catalog.compactMap { target in
            let url = target.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            guard let url else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return Installed(target: target, url: url, icon: icon)
        }
    }

    /// Carries out `action` with the app at `appURL`.
    @MainActor
    static func perform(_ action: OpenInTarget.Action, with appURL: URL) async throws {
        switch action {
        case .showFolder(let path):
            guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        case .reveal(let path):
            reveal(path)
        case .open(let path):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open(
                [URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: configuration
            )
        }
    }

    /// Selects `path` in its Finder folder.
    @MainActor
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The header's Open-in split button beside the working directory (Codex
/// `fileViewer.openInAnotherApp`): the icon opens the folder in the app used
/// last, the chevron lists every installed one.
struct OpenInControl: View {
    @Environment(ChatAppModel.self) private var model
    let directory: String

    var body: some View {
        let apps = model.openInApps
        if let preferred = model.preferredOpenInTarget, let primary = apps.first(where: { $0.id == preferred.id }) {
            HStack(spacing: 0) {
                Button {
                    open(in: primary.id)
                } label: {
                    Image(nsImage: primary.icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .padding(.leading, 7)
                        .padding(.trailing, 3)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在\(primary.target.name)中打开")
                .accessibilityLabel("在\(primary.target.name)中打开")
                .accessibilityIdentifier("header.openIn")

                Menu {
                    ForEach(apps) { app in
                        Button {
                            open(in: app.id)
                        } label: {
                            Label {
                                Text(app.target.name)
                            } icon: {
                                Image(nsImage: app.icon)
                            }
                        }
                        .accessibilityIdentifier("header.openIn.\(app.id)")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.ompTextTertiary)
                        .padding(.leading, 2)
                        .padding(.trailing, 7)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("用其他应用打开")
                .accessibilityIdentifier("header.openIn.menu")
            }
            .background(Color.ompFill, in: Capsule())
        }
    }

    private func open(in targetID: String) {
        let directory = directory
        Task { await model.open(directory, in: targetID) }
    }
}

/// The context menu of message text that mentions files (official
/// `markdown.fileReference.*`): one reference's actions directly, several
/// references each in a submenu.
struct FileReferenceMenu: View {
    let model: ChatAppModel
    let references: [FileReferenceResolver.Resolved]

    var body: some View {
        if references.count == 1, let only = references.first {
            items(only)
        } else {
            ForEach(references, id: \.self) { reference in
                Menu(Self.title(reference)) { items(reference) }
            }
        }
    }

    @ViewBuilder
    private func items(_ reference: FileReferenceResolver.Resolved) -> some View {
        let path = reference.path
        Button(reference.kind == .directory ? "打开文件夹" : "打开文件") {
            model.openFileInSidePanel(path, line: reference.reference.line)
        }
        Button("在访达中显示") { model.revealInFinder(path) }
        Button("拷贝路径") { model.copyFilePath(path) }
        if reference.kind == .file {
            Button("拷贝文件内容") { model.copyFileContents(path) }
        }
        Menu("打开方式") {
            ForEach(model.openInApps) { app in
                Button {
                    Task { await model.open(path, in: app.id) }
                } label: {
                    Label {
                        Text(app.target.name)
                    } icon: {
                        Image(nsImage: app.icon)
                    }
                }
            }
        }
    }

    /// `src/a.swift:12` as the model wrote it.
    private static func title(_ reference: FileReferenceResolver.Resolved) -> String {
        guard let line = reference.reference.line else { return reference.reference.path }
        return "\(reference.reference.path):\(line)"
    }
}
#endif
