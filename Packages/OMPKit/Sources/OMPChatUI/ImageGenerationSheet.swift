import SwiftUI
import OMPCore
import OMPDesign

public struct ImageGenerationSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var size = "1024x1024"
    @State private var modelID = ""
    @State private var running = false

    private let sizes = ["1024x1024", "1024x1536", "1536x1024", "512x512"]

    public init() {}

    private var imageModel: ModelDescriptor? {
        model.imageModels.first { $0.id == modelID } ?? model.imageModels.first
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("提示词") {
                    TextField("描述要生成的图片", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("参数") {
                    Picker("模型", selection: $modelID) {
                        ForEach(model.imageModels) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    Picker("尺寸", selection: $size) {
                        ForEach(sizes, id: \.self) { Text($0).tag($0) }
                    }
                }
                if running {
                    Section {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView().controlSize(.small)
                            Text("生成中…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("生成图片")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") { generate() }
                        .disabled(running || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if modelID.isEmpty { modelID = model.imageModels.first?.id ?? "" }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private func generate() {
        guard let imageModel else { return }
        running = true
        let prompt = prompt
        let size = size
        Task {
            await model.generateImage(prompt: prompt, model: imageModel, size: size)
            running = false
            dismiss()
        }
    }
}
