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

    private let efforts = [
        ("low", "快速"),
        ("medium", "平衡"),
        ("high", "深度"),
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("这段对话的专属指令，覆盖全局系统提示词", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
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
