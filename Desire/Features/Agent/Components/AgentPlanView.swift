import SwiftUI

/// Live task checklist rendered above the conversation while the agent
/// works through a multi-step plan (fed by the updatePlan tool).
struct AgentPlanView: View {
    let steps: [AgentPlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("任务计划")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(progressText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.6)
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
