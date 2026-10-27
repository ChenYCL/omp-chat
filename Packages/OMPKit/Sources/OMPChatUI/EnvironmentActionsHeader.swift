#if os(macOS)
import SwiftUI
import OMPCore
import OMPDesign

/// The header's environment actions (official `threadHeader` toolbar): the
/// selected local environment's commands for this platform, up to three
/// inline icon buttons and the rest in an overflow menu. A click opens the
/// side panel's terminal and runs the command there, through the model's
/// `runEnvironmentAction`.
///
/// Discovery runs in `.task`, never in `body`: the listing touches the disk
/// and the results live in `@State` until the directory or the selection
/// changes.
struct EnvironmentActionsHeader: View {
    @Environment(ChatAppModel.self) private var model
    let conversationID: UUID
    let directory: String

    @State private var actions: [LocalEnvironmentAction] = []

    /// Re-listed when the thread's directory or the project's selection
    /// changes; both are cheap dictionary lookups between renders.
    var body: some View {
        Group {
            if !actions.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(actions.prefix(3).enumerated()), id: \.element.id) { index, action in
                        actionButton(action, index: index)
                    }
                    if actions.count > 3 {
                        Menu {
                            ForEach(Array(actions.enumerated().dropFirst(3)), id: \.element.id) { index, action in
                                Button {
                                    run(index)
                                } label: {
                                    Label(action.name, systemImage: action.symbolName)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.ompTextSecondary)
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("更多环境动作")
                        .accessibilityIdentifier("environmentActionsOverflow")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("environmentActions")
            }
        }
        .task(id: directory) { reload() }
        .task(id: selectionKey) { reload() }
    }

    private var selectionKey: String {
        model.settings.localEnvironmentSelections[LocalEnvironmentDiscovery.standardize(directory)] ?? ""
    }

    private func actionButton(_ action: LocalEnvironmentAction, index: Int) -> some View {
        Button {
            run(index)
        } label: {
            Image(systemName: action.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.officialSM, style: .continuous)
                        .fill(Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(action.name)（\(action.command)）")
        .accessibilityIdentifier("environmentAction.\(index)")
    }

    private func run(_ index: Int) {
        if let failure = model.runEnvironmentAction(index: index, in: conversationID) {
            model.showError(failure)
        }
    }

    private func reload() {
        let files = model.localEnvironments(forProject: directory)
        let selected = model.selectedLocalEnvironmentPath(forProject: directory)
        let chosen = selected.map { LocalEnvironmentDiscovery.standardize($0) }
        let environment = files.first {
            chosen != nil && LocalEnvironmentDiscovery.standardize($0.path) == chosen
        }?.environment
        actions = environment?.actions(for: .current) ?? []
    }
}
#endif
