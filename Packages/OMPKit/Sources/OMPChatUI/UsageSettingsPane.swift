#if os(macOS)
import SwiftUI
import Charts
import OMPCore
import OMPDesign

/// Desktop settings → 用量: workspace token usage from `UsageSummary`.
struct UsageSettingsPane: View {
    @Environment(ChatAppModel.self) private var model
    /// Called after a top conversation is selected, so settings can close.
    let onSelectConversation: () -> Void

    var body: some View {
        let usage = UsageSummary(conversations: model.conversations)
        VStack(alignment: .leading, spacing: 16) {
            totalsGrid(usage)
            dailyChart(usage.daily)
            topConversations(usage.topConversations)
            byModel(usage.byModel)
            Text("消息不记录生成它的模型，「按对话模型」按每个对话当前的模型归类。合计 = 输入 + 输出，推理已含在输出里。已归档和临时对话同样消耗了 Token，也计入统计；已删除的对话不计入。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func totalsGrid(_ usage: UsageSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile("累计 Token", usage.all.totalTokens, id: "settings.usage.total")
                tile("最近 7 天", usage.last7Days.totalTokens, id: "settings.usage.last7")
                tile("最近 30 天", usage.last30Days.totalTokens, id: "settings.usage.last30")
            }
            GridRow {
                tile("输入", usage.all.inputTokens, id: "settings.usage.input")
                tile("输出（其中推理 \(TokenFormat.compact(usage.all.reasoningTokens))）", usage.all.outputTokens, id: "settings.usage.output")
                tile("请求次数", usage.all.requests, compact: false, id: "settings.usage.requests")
            }
        }
    }

    private func tile(_ title: String, _ value: Int, compact: Bool = true, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextSecondary)
                .lineLimit(1)
            Text(compact ? TokenFormat.compact(value) : "\(value)")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ompText)
                .help("\(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func dailyChart(_ days: [UsageSummary.Day]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近 14 天")
            Chart(days) { day in
                BarMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("Token", day.totalTokens)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) { Text(TokenFormat.compact(tokens)) }
                    }
                }
            }
            .frame(height: 160)
            .accessibilityIdentifier("settings.usage.dailyChart")
        }
    }

    private func topConversations(_ items: [UsageSummary.ConversationUsage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("用量最多的对话")
            if items.isEmpty {
                emptyRow("还没有带用量记录的回复")
            }
            ForEach(items) { item in
                Button {
                    model.selectedConversationID = item.id
                    onSelectConversation()
                } label: {
                    HStack {
                        Text(item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompText)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.totals.requests) 次 · \(TokenFormat.compact(item.totals.totalTokens))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.ompTextSecondary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开这个对话")
                .accessibilityIdentifier("settings.usage.topConversation")
                Divider()
            }
        }
    }

    private func byModel(_ groups: [UsageSummary.ModelUsage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("按对话模型")
            if groups.isEmpty {
                emptyRow("暂无数据")
            }
            ForEach(groups) { group in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(modelName(group.modelID))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text("\(group.conversations) 个对话 · \(group.totals.requests) 次请求")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    Spacer()
                    Text(TokenFormat.compact(group.totals.totalTokens))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.usage.model")
                Divider()
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 4)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.ompTextTertiary)
            .padding(.vertical, 6)
    }

    private func modelName(_ modelID: String?) -> String {
        guard let modelID else { return "默认模型" }
        return model.models.first { $0.id == modelID }?.displayName ?? modelID
    }
}
#endif
