import SwiftUI

/// Agent 状态弹窗（输入框左侧按钮点开）：模型 / 目标页 / 上下文 / 用量 /
/// 权限 / 本回合控制。
///
/// 这些信息此前是**常驻在输入框上方的一条**（模型名 + FULL ACCESS 徽标 + …），
/// 把聊天区压掉一大截、也让底部很杂。改成按需弹出后，底部只剩输入框。
struct AgentStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let busy: Bool
    let paused: Bool
    let model: String
    let contextPercent: Int
    let elapsed: Int?
    let contextLabel: String?
    let fullAccess: Bool
    let tokens: Int?
    let cost: String?
    /// 回合进行中才提供（nil = 不显示对应按钮）
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    statsGrid
                    permissionCard
                    if busy { controlCard }
                }
                .desirePagePadding()
                .padding(.vertical, 12)
            }
            .background(DesireUI.pageFill.ignoresSafeArea())
            .navigationTitle("Agent 状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
    }

    // MARK: - 概览

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            DesireIconBadge(icon: "sparkles", size: 40, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isEmpty ? "未配置模型" : model)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if busy { AgentBusyDot() }
                    Text(runStateText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let contextLabel, !contextLabel.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                            .font(.system(size: 9))
                        Text(contextLabel)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .desireCard()
    }

    private var runStateText: String {
        if paused { return "已暂停 · 等待继续" }
        if busy { return elapsed.map { "工作中 · \($0)s" } ?? "工作中" }
        return "就绪"
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            DesireStatTile(
                icon: "gauge.medium", title: "上下文",
                value: "\(contextPercent)%", tint: contextColor)
            DesireStatTile(
                icon: "text.word.spacing", title: "Token",
                value: tokens.map(DesireUI.formatTokens) ?? "—")
            DesireStatTile(
                icon: "dollarsign.circle", title: "成本",
                value: cost ?? "—")
        }
    }

    private var contextColor: Color {
        if contextPercent >= 85 { return .red }
        if contextPercent >= 60 { return .orange }
        return DesireUI.brand
    }

    // MARK: - 权限

    private var permissionCard: some View {
        DesireSection(title: "权限") {
            HStack(alignment: .top, spacing: 10) {
                DesireIconBadge(
                    icon: "bolt.shield.fill",
                    tint: fullAccess ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fullAccess ? "FULL ACCESS 已开启" : "逐次审批")
                        .font(.system(size: 15, weight: .medium))
                    Text(fullAccess
                         ? "所有工具直接执行，包括在页面上运行任意 JavaScript。"
                         : "改变状态与执行代码的工具会先请你确认。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 本回合控制

    private var controlCard: some View {
        DesireSection(title: "本回合") {
            HStack(spacing: 8) {
                if let onPauseToggle {
                    controlButton(
                        paused ? "继续" : "暂停",
                        icon: paused ? "play.fill" : "pause.fill",
                        tint: paused ? .green : .orange,
                        action: onPauseToggle)
                }
                if let onStop {
                    controlButton("停止", icon: "stop.fill", tint: .red, action: onStop)
                }
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)
        }
    }

    private func controlButton(
        _ title: String, icon: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.chipCorner, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

/// 工作中的呼吸点（区别于录音的红点）。
struct AgentBusyDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RootView.brand.opacity(0.25))
                .frame(width: 10, height: 10)
                .scaleEffect(pulsing ? 1.5 : 1.0)
            Circle()
                .fill(RootView.brand)
                .frame(width: 5, height: 5)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// updatePlan 任务清单（对应桌面 AgentPlanView）。可折叠，默认展开。
struct PlanStripView: View {
    let steps: [RemotePlanStep]
    @State private var expanded = true

    private static let visibleLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(RootView.brand)
                    Text("任务计划")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(progressText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(visibleSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: iconName(step.status))
                            .font(.system(size: 11))
                            .foregroundStyle(iconColor(step.status))
                            .frame(width: 14)
                        Text(step.content)
                            .font(.system(size: 11.5, weight: step.status == "in_progress" ? .semibold : .regular))
                            .foregroundStyle(step.status == "done" ? Color.secondary : Color.primary)
                            .strikethrough(step.status == "done")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                if steps.count > Self.visibleLimit {
                    Text("+\(steps.count - Self.visibleLimit) 步")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RootView.brand.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RootView.brand.opacity(0.2), lineWidth: 0.6)
        )
    }

    private var visibleSteps: [RemotePlanStep] {
        Array(steps.prefix(Self.visibleLimit))
    }

    private var progressText: String {
        "\(steps.filter { $0.status == "done" }.count)/\(steps.count)"
    }

    private func iconName(_ status: String) -> String {
        switch status {
        case "done": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }

    private func iconColor(_ status: String) -> Color {
        switch status {
        case "done": .green
        case "in_progress": .orange
        default: .secondary.opacity(0.6)
        }
    }
}

/// 子代理实时进度（spawnSubagent）。
struct SubagentStripView: View {
    let subagents: [RemoteSubagent]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(subagents.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(RootView.brand)
                    Text(run.label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tool = run.tool, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RootView.brand)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(RootView.brand.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                    Text("\(run.step)/\(run.maxSteps)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
    }
}

/// 回合进行中输入、排队待发的消息：可逐条移除 / 全部清空。
struct QueuedStripView: View {
    let queued: [RemoteQueued]
    let onRemove: (String) -> Void
    let onClearAll: () -> Void

    private static let visibleLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("排队 \(queued.count) 条")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("全部清空", action: onClearAll)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            ForEach(queued.prefix(Self.visibleLimit)) { item in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(item.text)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button { onRemove(item.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if queued.count > Self.visibleLimit {
                Text("还有 \(queued.count - Self.visibleLimit) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}
