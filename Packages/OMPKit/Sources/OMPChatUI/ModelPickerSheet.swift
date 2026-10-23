import SwiftUI
import OMPCore
import OMPDesign

/// Full searchable model picker sheet supporting 100+ models with
/// capability tags (Thinking, Vision), context window badges, and provider tags.
public struct ModelPickerSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    public init() {}

    private var filteredModels: [ModelDescriptor] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.availableModels }
        return model.availableModels.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextTertiary)
                    TextField("搜索模型 (如 deepseek, claude, gpt-4o, flash...)", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Models List
                List {
                    Section {
                        ForEach(filteredModels) { descriptor in
                            Button {
                                model.setModel(descriptor)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    if descriptor.id == model.activeModel?.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.ompBorder, lineWidth: 1)
                                            .frame(width: 14, height: 14)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(descriptor.displayName)
                                                .font(.system(size: 13.5, weight: .semibold))
                                                .foregroundStyle(Color.ompText)
                                            if let provider = model.providers.first(where: { $0.id == descriptor.providerID }) {
                                                Text(provider.name)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Color.ompTextTertiary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.ompFill, in: Capsule())
                                            }
                                        }

                                        Text(descriptor.id)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.ompTextTertiary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    // Capabilities pills
                                    HStack(spacing: 4) {
                                        if descriptor.capabilities.thinking {
                                            Text("🧠 思考")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Color.purple)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.1), in: Capsule())
                                        }
                                        if descriptor.capabilities.vision {
                                            Text("👁 视觉")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Color.blue)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.1), in: Capsule())
                                        }
                                        if let limit = descriptor.limits.contextWindow {
                                            Text(TokenFormat.compact(limit))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Color.ompTextSecondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.ompFill, in: Capsule())
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("可用模型 (\(filteredModels.count) / \(model.availableModels.count))")
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("选择模型 (Models)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }
}
