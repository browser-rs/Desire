import SwiftUI

/// Live task checklist rendered above the conversation while the agent
/// works through a multi-step plan (fed by the updatePlan tool).
struct AgentPlanView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let steps: [AgentPlanStep]

    /// 步骤区的自然高度（实测）。**弹性高度**：内容多高卡多高，只有超过
    /// 封顶才滚动——`.frame(maxHeight:)` 那种写法不行，它对 VStack 的剩余
    /// 空间提案照单全收（3 步也能撑满 176pt、内容被居中悬空，用户实测
    /// "高度定死了吗"），必须把框钉在实测内容高度上。
    @State private var contentHeight: CGFloat = 0
    /// 封顶：计划块是非滚动固定区，无界高度会把浮窗 fitting 顶破最小尺寸、
    /// 窗口高度锁死无法调节（上一轮修的回归）。超出部分在卡内滚动。
    private let maxHeight: CGFloat = 176

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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
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
