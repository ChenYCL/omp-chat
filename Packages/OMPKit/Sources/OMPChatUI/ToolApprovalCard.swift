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

/// Composer menu for whether the agent gets tools in this thread and how
/// freely they run: one radio list (`AgentAccess`), like Codex's Chat /
/// Agent / Agent (full access) picker, so exactly one entry is checked and
/// every pick changes what the button shows.
struct AgentModeMenu: View {
    let conversationID: UUID
    @Environment(ChatAppModel.self) private var model

    var body: some View {
        let access = model.agentAccess(for: conversationID)
        // What 跟随默认 gives right now, shown next to that entry.
        let fallback = model.defaultAgentAccess(for: conversationID)
        let effective = model.effectiveAgentAccess(for: conversationID)
        Menu {
            Picker("工具与权限", selection: Binding(
                get: { access },
                set: { model.setAgentAccess($0, for: conversationID) }
            )) {
                ForEach(AgentAccess.allChoices, id: \.self) { choice in
                    Text(choice == .followDefault ? "跟随默认（\(fallback.title)）" : choice.title)
                        .tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: effective == .chatOnly ? "bubble.left" : "hammer")
                    .font(.system(size: 10))
                Text(effective.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.ompTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("仅聊天：不调用工具。只读：只能读。每次询问：读直接执行，改文件和运行命令先问你。自动：改工作目录里的文件不问，运行命令先问。完全访问：文件和命令都不问，控制电脑仍要问。跟随默认：有工作目录时用设置里的默认权限，没有时仅聊天。")
        .accessibilityIdentifier("composer.agentMode")
        .accessibilityValue(effective.title)
    }
}
