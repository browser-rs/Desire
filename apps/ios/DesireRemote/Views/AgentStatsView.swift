import SwiftUI

/// 用量统计（Agent Tab → 用量统计）：与 Mac 桌面「用量」页、桥 `/agent/stats`
/// 同一份口径（Mac 端 `UsageStats.derive`）。
struct AgentStatsView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let stats = client.stats {
                    if stats.turns == 0 && stats.conversations == 0 {
                        DesireEmptyState(
                            icon: "chart.bar.xaxis",
                            title: "还没有用量数据",
                            message: "在 Mac 上完成几轮对话后，这里会统计 token 与成本。")
                    } else {
                        overviewGrid(stats)
                        costSection(stats)
                        if !stats.models.isEmpty {
                            modelSection(stats)
                        }
                    }
                } else {
                    loadingCard
                }
            }
            .desirePagePadding()
            .padding(.vertical, 12)
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .navigationTitle("用量统计")
        .navigationBarTitleDisplayMode(.inline)
        .task { client.requestStats() }
        .refreshable { client.requestStats() }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在统计 Mac 上的历史用量…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .desireCard()
    }

    private func overviewGrid(_ stats: RemoteStats) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            DesireStatTile(
                icon: "text.word.spacing", title: "总 Token",
                value: DesireUI.formatTokens(stats.totalTokens))
            DesireStatTile(
                icon: "arrow.down.circle", title: "输入",
                value: DesireUI.formatTokens(stats.promptTokens))
            DesireStatTile(
                icon: "arrow.up.circle", title: "输出",
                value: DesireUI.formatTokens(stats.completionTokens))
            DesireStatTile(
                icon: "bubble.left.and.bubble.right", title: "回合 / 对话",
                value: "\(stats.turns) / \(stats.conversations)")
        }
    }

    private func costSection(_ stats: RemoteStats) -> some View {
        DesireSection(title: "成本") {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DesireUI.formatUSD(stats.cost) ?? "—")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(stats.cost == nil ? .secondary : .primary)
                    if stats.cost == nil && stats.unpricedTokens > 0 {
                        Text("有未定价的调用")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                // 未定价就**不给总额**（与 Mac 同口径：宁可不说，也不给一个会被
                // 当成真总额的半成品数字），这里如实说明原因。
                if stats.unpricedTokens > 0 {
                    DesireValueRow(
                        title: "未定价 Token",
                        value: DesireUI.formatTokens(stats.unpricedTokens),
                        valueColor: .orange)
                }
                DesireValueRow(
                    title: "单日峰值",
                    value: DesireUI.formatTokens(stats.peakDayTokens ?? 0))
                DesireValueRow(
                    title: "最长一次对话",
                    value: DesireUI.formatDuration(stats.longestConversationSeconds))
                DesireValueRow(
                    title: "连续使用",
                    value: "当前 \(stats.currentStreak) 天 · 最长 \(stats.longestStreak) 天")
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)
        }
    }

    private func modelSection(_ stats: RemoteStats) -> some View {
        DesireSection(title: "按模型", subtitle: "token 与成本明细") {
            ForEach(Array(stats.models.enumerated()), id: \.element.id) { index, item in
                if index > 0 { DesireRowDivider() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesireUI.brand)
                        .frame(width: 18)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.model)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text(DesireUI.formatTokens(item.tokens))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let cost = DesireUI.formatUSD(item.cost) {
                                Text(cost)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesireUI.cardPadding)
                .padding(.vertical, 10)
            }
        }
    }
}
