import SwiftUI
#if os(macOS)
import AppKit
#endif
import OMPCore
import OMPDesign

/// Bottom-centre capsule after an undoable sidebar action (Codex `appUndo`):
/// the message and 撤销. It goes after six seconds — held while the pointer
/// rests on it — or is replaced by the next action; an undo's result then
/// shows briefly in its place.
struct UndoToast: View {
    @Environment(ChatAppModel.self) private var model
    @State private var hovering = false

    private static let actionLifetime: Duration = .seconds(6)
    private static let resultLifetime: Duration = .milliseconds(2500)

    private struct Lifetime: Equatable {
        var id: UUID
        var hovering: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let toast = model.undoToast {
                capsule(toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: Lifetime(id: toast.id, hovering: hovering)) {
                        // Hovering cancels the countdown; leaving starts it over.
                        guard !hovering else { return }
                        try? await Task.sleep(for: toast.offersUndo ? Self.actionLifetime : Self.resultLifetime)
                        guard !Task.isCancelled, model.undoToast?.id == toast.id else { return }
                        model.dismissUndoToast()
                    }
            }
        }
        .frame(maxWidth: .infinity)
        // Clears the composer at the bottom of the chat.
        .padding(.bottom, 120)
        .animation(Theme.Motion.quick, value: model.undoToast?.id)
        #if os(macOS)
        .onAppear { UndoShortcut.install(model) }
        #endif
    }

    private func capsule(_ toast: AppUndoToast) -> some View {
        HStack(spacing: 14) {
            Text(toast.message)
                .font(.system(size: 13))
                .foregroundStyle(Color.ompText)
                .lineLimit(1)
                .truncationMode(.middle)
            if toast.offersUndo {
                Button("撤销") { model.undoLast() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("undoToast.undo")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .frame(maxWidth: 440)
        .background(Capsule().fill(Color.ompCard))
        .overlay(Capsule().stroke(Color.ompBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undoToast")
    }
}

#if os(macOS)
/// Edit menu 撤销「…」 for the newest sidebar action.
///
/// The item has no key equivalent on purpose. AppKit resolves ⌘Z by menu key
/// equivalent: the system Undo item sends `undo:` down the responder chain,
/// which a focused text field answers with its own typing history. A second
/// ⌘Z item would compete with it (and win whenever the field has nothing to
/// undo, since SwiftUI cannot re-validate it against the first responder at
/// key time). `UndoShortcut` handles ⌘Z instead, deciding per key press.
public struct AppUndoCommands: Commands {
    let model: ChatAppModel

    public init(model: ChatAppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Button(model.undoStack.top.map { "撤销「\($0.message)」" } ?? "撤销侧栏操作") {
                model.undoLast()
            }
            .disabled(model.undoStack.top == nil)
        }
    }
}

/// ⌘Z for the sidebar undo, only when AppKit's own undo would not act: no
/// text input is first responder (field editor, text view, terminal, web
/// view — anything taking typed text), and the responder chain's undo
/// manager has nothing to undo. Otherwise the event passes through untouched.
@MainActor
enum UndoShortcut {
    private static var monitor: Any?

    /// Once per app: there is one model, and one monitor sees every window.
    static func install(_ model: ChatAppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            // Local monitors run on the main thread.
            let undone = MainActor.assumeIsolated { () -> Bool in
                guard let model, isPlainCommandZ(event), model.undoStack.top != nil,
                      !appKitWouldUndo(in: event.window) else { return false }
                model.undoLast()
                return true
            }
            return undone ? nil : event
        }
    }

    private static func isPlainCommandZ(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func appKitWouldUndo(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSText || responder is NSTextInputClient { return true }
        return responder.undoManager?.canUndo == true
    }
}
#endif
