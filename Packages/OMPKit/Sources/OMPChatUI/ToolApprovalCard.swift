import SwiftUI
import OMPCore
import OMPDesign

/// One tool call waiting for the user (Codex's approval prompt). The agent loop
/// is suspended on it; the buttons resolve it through the model, and 停止
/// refuses it.
struct ToolApprovalCard: View {
    let request: ToolApprovalRequest
    @Environment(ChatAppModel.self) private var model
    @State private var showArguments = false

    private var riskTitle: String { request.risk.title }

    private var riskColor: Color {
        switch request.risk {
        case .read: Color.ompTextSecondary
        case .write: Color.orange
        case .execute: Color.orange
        case .control: Color.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: request.risk == .control ? "cursorarrow.click.2" : "exclamationmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(riskColor)
                Text("需要你的批准 · \(riskTitle)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ompText)
                Spacer(minLength: 0)
                Text(request.source)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ompTextTertiary)
            }
            Text(request.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ompText)
                .textSelection(.enabled)
                .lineLimit(6)
                .accessibilityIdentifier("approval.summary")
            if !request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup(isExpanded: $showArguments) {
                    ScrollView {
                        Text(request.argumentsJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.ompTextSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Text("参数")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ompTextSecondary)
                }
            }
            HStack(spacing: 8) {
                Button("允许一次") { model.resolveApproval(request.id, .allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("approval.allowOnce")
                // Desktop control always asks; offering "always" there would be
                // a button the loop ignores.
                if request.risk != .control {
                    Button("本次会话始终允许") { model.resolveApproval(request.id, .allowAlways) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("在应用退出前，这个工具不再询问")
                        .accessibilityIdentifier("approval.allowAlways")
                }
                Button("拒绝", role: .destructive) { model.resolveApproval(request.id, .deny) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("approval.deny")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(riskColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.card")
    }
}

/// Composer menu for how freely the agent may act in this thread, and whether
/// it gets tools at all. Both default to following settings / the thread's
/// working directory, shown as 「跟随默认」 / 「自动」.
struct AgentModeMenu: View {
    let conversationID: UUID
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        let mode = model.permissionMode(for: conversationID)
        let toolsOn = model.toolsEnabled(for: conversationID)
        Menu {
            Section("工具") {
                Toggle("允许使用工具", isOn: Binding(
                    get: { toolsOn },
                    set: { model.setToolsEnabled($0, for: conversationID) }
                ))
                Button("跟随工作目录（有目录时开启）") { model.setToolsEnabled(nil, for: conversationID) }
            }
            Section("权限") {
                ForEach(PermissionMode.allCases, id: \.self) { option in
                    Button {
                        model.setPermissionMode(option, for: conversationID)
                    } label: {
                        if option == mode {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
                Button("跟随默认") { model.setPermissionMode(nil, for: conversationID) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: toolsOn ? "hammer" : "bubble.left")
                    .font(.system(size: 10))
                Text(toolsOn ? mode.title : "仅聊天")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.ompTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("工具与权限：只读 / 每次询问 / 自动 / 完全访问")
        .accessibilityIdentifier("composer.agentMode")
    }
}
