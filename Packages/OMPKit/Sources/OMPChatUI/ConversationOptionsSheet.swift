import SwiftUI
import OMPCore
import OMPDesign

/// Per-conversation options: custom instructions and reasoning effort,
/// matching ChatGPT's custom instructions and reasoning selector.
public struct ConversationOptionsSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var effort = "medium"
    @State private var selectedPersonaIndex: Int? = nil

    private let personas: [(title: String, icon: String, prompt: String)] = [
        ("通用助理", "sparkles", ""),
        ("代码架构师", "laptopcomputer", "你是一位资深的系统架构师与高级工程师。回答时先给设计结论、架构约束与代码验证，使用类型安全的惯用代码，避免冗余抽象。"),
        ("排错专家", "stethoscope", "你是一位资深排错专家。遵循根因分析原则：先确认现象与错误现场，分析可能原因并提出最小修复验证方案。"),
        ("安全审计", "shield.checkerboard", "你是一位代码与协议安全审计专家。重点关注输入验证、内存边界、身份鉴权、命令注入与敏感凭据保护。"),
        ("技术写作", "doc.text", "你是一位专业的技术文档写作专家。使用严谨清晰的技术文风，段落简练，结构清晰，表格与代码块排版得当。")
    ]
    private let efforts = [
        ("low", "快速"),
        ("medium", "平衡"),
        ("high", "深度"),
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("智能角色预设 (Personas)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(personas.enumerated()), id: \.offset) { index, persona in
                                Button {
                                    selectedPersonaIndex = index
                                    prompt = persona.prompt
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: persona.icon)
                                            .font(.system(size: 11))
                                        Text(persona.title)
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(selectedPersonaIndex == index ? Color.white : Color.ompText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedPersonaIndex == index ? Color.accentColor : Color.ompFill,
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    TextField("这段对话的专属指令，覆盖全局系统提示词", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(size: 13))
                } header: {
                    Text("自定义指令")
                } footer: {
                    Text("留空则使用设置里的全局系统提示词。")
                        .font(.caption2)
                }

                Section("推理强度") {
                    Picker("推理强度", selection: $effort) {
                        ForEach(efforts, id: \.0) { item in
                            Text(item.1).tag(item.0)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(effortDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("对话设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                prompt = model.selectedConversation?.systemPrompt ?? ""
                effort = model.selectedConversation?.reasoningEffort ?? "medium"
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 340)
        #endif
    }

    private var effortDescription: String {
        switch effort {
        case "low": "更快的回复，思考预算更小。"
        case "high": "更深入的推理，耗时更长。"
        default: "速度与质量折中。"
        }
    }

    private func save() {
        model.setConversationPrompt(prompt)
        model.setReasoningEffort(effort)
        dismiss()
    }
}
