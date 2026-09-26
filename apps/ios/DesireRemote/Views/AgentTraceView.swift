import SwiftUI

/// 执行轨迹（Agent Tab → 执行轨迹）：当前对话每个回合实际做了什么
/// ——目标、工具调用序列与每步耗时、是否被拒/报错、最终回答与用量。
///
/// 数据来自 Mac 的 `AgentTrace.turns`（从会话本身派生，与桌面「轨迹」页同源），
/// 只回最近 20 个回合。
struct AgentTraceView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var expanded: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let trace = client.trace {
                    if trace.turns.isEmpty {
                        DesireEmptyState(
                            icon: "point.topleft.down.to.point.bottomright.curvepath",
                            title: "这个对话还没有轨迹",
                            message: "在 Mac 上跑完一轮对话后，这里会显示 Agent 实际执行的每一步。")
                    } else {
                        statsGrid(trace.stats)
                        diagnosticsSection(trace.stats)
                        turnSection(trace.turns)
                    }
                } else {
                    loadingCard
                }
            }
            .desirePagePadding()
            .padding(.vertical, 12)
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .navigationTitle("执行轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .task { client.requestTrace() }
        .refreshable { client.requestTrace() }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在从 Mac 读取轨迹…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .desireCard()
    }

    private func statsGrid(_ stats: RemoteTraceStats) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            DesireStatTile(icon: "arrow.triangle.2.circlepath", title: "回合",
                           value: "\(stats.turns ?? 0)")
            DesireStatTile(icon: "wrench.and.screwdriver", title: "工具调用",
                           value: "\(stats.toolCalls ?? 0)")
            DesireStatTile(
                icon: "hand.raised", title: "被你拒绝",
                value: "\(stats.denied ?? 0)",
                tint: (stats.denied ?? 0) > 0 ? .orange : DesireUI.brand)
            DesireStatTile(
                icon: "exclamationmark.triangle", title: "执行失败",
                value: "\(stats.threwError ?? 0)",
                tint: (stats.threwError ?? 0) > 0 ? .red : DesireUI.brand)
        }
    }

    private func diagnosticsSection(_ stats: RemoteTraceStats) -> some View {
        DesireSection(title: "诊断", subtitle: "哪一步慢、哪一步容易失败") {
            VStack(spacing: 10) {
                DesireValueRow(
                    title: "平均工具耗时",
                    value: DesireUI.formatMs(stats.avgToolMs ?? 0),
                    mono: true)
                DesireValueRow(
                    title: "Token（输入 / 输出）",
                    value: "\(DesireUI.formatTokens(stats.promptTokens ?? 0)) / \(DesireUI.formatTokens(stats.completionTokens ?? 0))",
                    mono: true)
                DesireValueRow(
                    title: "成本",
                    value: DesireUI.formatUSD(stats.cost) ?? (stats.costIncomplete == true ? "含未定价调用" : "—"),
                    valueColor: stats.cost == nil && stats.costIncomplete == true ? .orange : .secondary,
                    mono: true)
                if let unverified = stats.unverifiedTurns, unverified > 0 {
                    DesireValueRow(title: "带核验提示的回合", value: "\(unverified)", valueColor: .orange)
                }
                let up = stats.votesUp ?? 0
                let down = stats.votesDown ?? 0
                if up + down > 0 {
                    DesireValueRow(title: "你的评价", value: "👍 \(up) · 👎 \(down)")
                }
                if let slowest = stats.slowestTools, !slowest.isEmpty {
                    toolStatBlock(title: "最慢的工具", items: slowest, showsAvg: true)
                }
                if let flakiest = stats.flakiestTools, !flakiest.isEmpty {
                    toolStatBlock(title: "最容易失败的工具", items: flakiest, showsAvg: false)
                }
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)
        }
    }

    private func toolStatBlock(
        title: String, items: [RemoteToolStat], showsAvg: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Text(item.tool)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(item.calls) 次")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if showsAvg, let avg = item.avgMs {
                        Text(DesireUI.formatMs(avg))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !showsAvg, let failed = item.failed {
                        Text("失败 \(failed)")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func turnSection(_ turns: [RemoteTraceTurn]) -> some View {
        DesireSection(
            title: "回合明细",
            subtitle: "最近 \(turns.count) 个回合（点开看每步）"
        ) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                if index > 0 { DesireRowDivider() }
                turnRow(turn)
            }
        }
    }

    private func turnRow(_ turn: RemoteTraceTurn) -> some View {
        let isOpen = expanded.contains(turn.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(turn.id) } else { expanded.insert(turn.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("第 \(turn.turn) 回合")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesireUI.brand)
                        Text("\(turn.toolCalls) 次工具")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let tokens = turn.tokens {
                            Text(DesireUI.formatTokens(tokens.total))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(turn.goal)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(isOpen ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                if !turn.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                            stepRow(step)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let answer = turn.answer, !answer.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("回答")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(answer)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: DesireUI.chipCorner, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
        .padding(.horizontal, DesireUI.cardPadding)
        .padding(.vertical, 11)
    }

    /// 一步工具：竖线串成的简易时间线。
    private func stepRow(_ step: RemoteTraceStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: step.failed == true ? "xmark.circle.fill"
                      : (step.denied == true ? "hand.raised.fill" : "checkmark.circle.fill"))
                    .font(.system(size: 10))
                    .foregroundStyle(stepColor(step))
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
                    .frame(minHeight: 12)
            }
            .frame(width: 14)

            HStack(spacing: 6) {
                Text(step.action)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if step.denied == true {
                    tag("被拒绝", color: .orange)
                } else if step.failed == true {
                    tag("失败", color: .red)
                }
                Spacer(minLength: 4)
                if let ms = step.ms {
                    Text(DesireUI.formatMs(ms))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func stepColor(_ step: RemoteTraceStep) -> Color {
        if step.failed == true { return .red }
        if step.denied == true { return .orange }
        return .green
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
