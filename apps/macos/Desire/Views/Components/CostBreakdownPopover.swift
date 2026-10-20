import SwiftUI

/// 本对话成本明细（v0.7.26）：按 **模型 × 类型** 拆开 token 与金额。
/// 数据来自 `CostBreakdown.derive`（与面板/轨迹/统计同一 `AgentUsage` 口径）。
struct CostBreakdownPopover: View {
    let breakdown: CostBreakdown.Result

    private func label(_ group: CostBreakdown.Group) -> String {
        switch group.category {
        case "main": return String(localized: "Main turns")
        case "subagent":
            return String(localized: "Subagent") + (group.kind.map { " · \($0)" } ?? "")
        default:
            return String(localized: "Bypass") + (group.kind.map { " · \($0)" } ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本对话成本")
                .font(.system(size: 12, weight: .semibold))
            if breakdown.groups.isEmpty {
                Text("还没有用量记录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(breakdown.groups) { group in
                    HStack(spacing: 6) {
                        Text(label(group))
                            .font(.system(size: 11))
                        if let model = group.model, !model.isEmpty {
                            Text(model)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(AgentUsage.formatTokens(group.totalTokens) + " tok")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(group.usd.map(AgentUsage.formatUSD) ?? "未定价")
                            .font(.system(size: 10))
                            .foregroundStyle(group.usd == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    }
                }
                Divider()
                HStack {
                    Text("合计")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(AgentUsage.formatTokens(breakdown.usage.totalTokens) + " tok")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(breakdown.usage.formattedUSD ?? "含未定价模型")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}
