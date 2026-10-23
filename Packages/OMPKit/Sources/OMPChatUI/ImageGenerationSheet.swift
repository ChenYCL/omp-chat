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

    private let stylePresets: [(name: String, suffix: String)] = [
        ("极简设计", ", 极简矢量设计, 干净纯色背景, 高品质"),
        ("3D 渲染", ", 3D 渲染风格, 光影质感, 细致建模, 8k 分辨率"),
        ("赛博朋克", ", 赛博朋克风格, 霓虹灯光, 科技感, 夜景"),
        ("扁平插画", ", 扁平现代插画, 温暖配色, 艺术排版"),
        ("动漫风", ", 日本动漫艺术风格, 精致线条, 唯美背景"),
        ("真实摄影", ", 真实胶片摄影, 50mm 镜头, 自然采光, 超高清")
    ]
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
                Section("风格预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(stylePresets, id: \.name) { preset in
                                Button {
                                    if !prompt.contains(preset.suffix) {
                                        prompt += preset.suffix
                                    }
                                } label: {
                                    Text(preset.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.ompFill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
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
