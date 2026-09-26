import SwiftUI

/// Agent 状态条（对应桌面输入框上方的状态行）：模型 / 上下文占用 / 用时 /
/// 全权限徽标 / 当前操作目标页，并在回合进行中提供暂停·继续与停止。
struct AgentStatusStripView: View {
    let busy: Bool
    let paused: Bool
    let model: String
    let contextPercent: Int
    let elapsed: Int?
    let contextLabel: String?
    let fullAccess: Bool
    /// 回合进行中才有意义（nil = 不显示对应按钮）
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if busy {
                    AgentBusyDot()
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if busy, let elapsed, !paused {
                    Text("\(elapsed)s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if contextPercent > 0 {
                    Text("上下文 \(contextPercent)%")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if fullAccess {
                    Text("FULL ACCESS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                if busy, let onPauseToggle {
                    controlChip(
                        icon: paused ? "play.fill" : "pause.fill",
                        tint: paused ? .green : .orange,
                        action: onPauseToggle)
                }
                if busy, let onStop {
                    controlChip(icon: "stop.fill", tint: .red, action: onStop)
                }
            }
            if let contextLabel, !contextLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 9))
                    Text(contextLabel)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }

    private func controlChip(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if paused { return model.isEmpty ? "已暂停" : "已暂停 · \(model)" }
        if busy { return model.isEmpty ? "Agent 工作中…" : "Agent 工作中 · \(model)" }
        return model.isEmpty ? "就绪" : model
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
