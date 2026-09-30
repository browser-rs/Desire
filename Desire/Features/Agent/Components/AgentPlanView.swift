import SwiftUI

/// Live task checklist rendered above the conversation while the agent
/// works through a multi-step plan (fed by the updatePlan tool).
struct AgentPlanView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let steps: [AgentPlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(appAccent)
                Text("任务计划")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(progressText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // **高度封顶 + 内部滚动**：计划块是非滚动固定区，12 步 ×长文案
            // 能把浮窗的 fitting 高度顶破最小尺寸——窗口高度因此锁死无法
            // 调节（用户实测：计划在则高度不可调，切换对话后恢复）。封顶后
            // 固定区有界，超出的步骤在卡内滚动。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
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
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 176)
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appAccent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(appAccent.opacity(0.2), lineWidth: 0.6)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var progressText: String {
        let done = steps.filter { $0.status == "done" }.count
        return "\(done)/\(steps.count)"
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
