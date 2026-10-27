import SwiftUI
import OMPDesign

/// The transcript card shown while a managed worktree is created (official
/// `worktreeInitV2.progress.*`): 正在获取最新改动 / 正在检出文件 / 正在运行初始化
/// 脚本, plus 失败 with the script or git output and the official 「跳过更新」.
struct WorktreeProgressCard: View {
    @Environment(ChatAppModel.self) private var model
    let progress: ManagedWorktreeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if progress.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ompText)
                Spacer(minLength: 8)
                if progress.canSkipFetch {
                    Button("跳过更新") {
                        model.skipWorktreeFetch(for: progress.conversationID)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help("停止获取，用本地已有的改动创建 Worktree")
                    .accessibilityIdentifier("worktree.progress.skip")
                }
            }
            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.ompTextSecondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Color.ompBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worktree.progress")
    }

    private var title: String {
        switch progress.phase {
        case .fetching: return "正在获取最新改动"
        case .checkingOut: return "正在检出文件"
        case .settingUp: return "正在运行初始化脚本"
        case .failed: return "Worktree 初始化失败"
        }
    }
}
