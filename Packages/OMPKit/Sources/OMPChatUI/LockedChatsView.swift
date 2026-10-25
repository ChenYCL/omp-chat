import SwiftUI
import LocalAuthentication
import OMPCore
import OMPDesign

/// Locked chats are hidden from Recents, pin lists and search until the device
/// owner authenticates (Touch ID / passcode). The desktop sidebar has this
/// section; this is the phone's screen for it.
public struct PaseoLockedSheet: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSelect: (UUID) -> Void

    @State private var unlocked = false
    @State private var failure: String?

    public init(onSelect: @escaping (UUID) -> Void) {
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.lockedConversations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "lock")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text("没有已锁定的会话")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.ompTextSecondary)
                        Text("在会话菜单里选「锁定」，它会移到这，并从最近和搜索里消失。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ompTextTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !unlocked {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text("已锁定")
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(model.lockedConversations.count) 个私密会话。验证面容、指纹或密码后可以查看。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.ompTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Button("验证并解锁") { authenticate() }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 6)
                        if let failure {
                            Text(failure)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ompFlat(rgb: 0xDE4A43))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(model.lockedConversations) { conv in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conv.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.ompText)
                                        .lineLimit(1)
                                    Text(conv.lastMessagePreview)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.ompTextSecondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(conv.id)
                                    dismiss()
                                }
                            }
                        } footer: {
                            Text("离开这个页面就会重新上锁。")
                                .font(.caption2)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.ompCanvas)
            .navigationTitle("已锁定")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        unlocked = false
                        dismiss()
                    }
                }
            }
            .onDisappear { unlocked = false }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics / passcode set: say so rather than showing an empty
            // list that implies the chats are gone.
            failure = "这台设备没有设置面容、指纹或密码，无法解锁。请先在系统设置里设置。"
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证以访问已锁定的私密会话") { ok, error in
            Task { @MainActor in
                if ok {
                    unlocked = true
                    failure = nil
                } else {
                    failure = error?.localizedDescription ?? "验证失败"
                }
            }
        }
    }
}
