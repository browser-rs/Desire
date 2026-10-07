import SwiftUI

/// Inline approval prompt shown above the input bar when the agent wants to
/// run a tool that isn't read-only (and isn't whitelisted).
///
/// Renders the tool name, a risk-tier badge (color-coded), a short summary
/// of the arguments, and three buttons:
/// - **Allow Once** — run this call only.
/// - **Always Allow** — whitelist the tool for future calls in this session
///   and beyond. Disabled for `.dangerous` tools (those always prompt).
/// - **Deny** — refuse; the agent is told the user declined.
///
/// See `docs/ARCHITECTURE.md` (AgentRuntime v2, roadmap L3 stage 2).
struct ToolApprovalBar: View {
    let approval: PendingToolApproval
    let onAllowOnce: () -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void
    /// DPP 逐动作放行（0.6.7）：pageAction 审批卡专属——「本站始终允许此动作」。
    /// host 取自审批锚点；为 nil（非 pageAction/无锚点）时不显示。
    var onAlwaysAllowOnSite: ((String) -> Void)? = nil
    /// 审批时记录的页面 host（供按钮文案）。
    var siteHost: String? = nil
    /// 跨源标注（0.7.2）：动作声明自跨源子框架时的框架 host——nil = 主框架声明。
    var sourceFrameHost: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            riskBadge
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(approval.toolCall.function.name)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                    Text(approval.risk.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(riskColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(riskColor)
                }
                if !approval.argumentsSummary.isEmpty {
                    Text(approval.argumentsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let sourceFrameHost {
                    Label("声明来自嵌入框架 \(sourceFrameHost)（跨源）——步骤将在该框架内执行",
                          systemImage: "square.stack.3d.forward.filled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Allow Once", action: onAllowOnce)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Always Allow", action: onAlwaysAllow)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(approval.risk == .dangerous)
                    if let onAlwaysAllowOnSite {
                        Button("Always on \(siteHost ?? "this site")", action: { onAlwaysAllowOnSite(siteHost ?? "") })
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Deny", role: .destructive, action: onDeny)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 2)
                // 逐动作放行的语义说明（0.6.7）：授权粒度是「站点 × 动作」，
                // 与 Always Allow（按工具名）不同层。
                if onAlwaysAllowOnSite != nil {
                    Text("“Always on this site”持久放行该站点的此动作（可吊销）——即使它被标记为不可逆。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(riskColor.opacity(0.06), in: RoundedRectangle(cornerRadius: .radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: .radiusCard)
                .strokeBorder(riskColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Risk visual

    private var riskBadge: some View {
        Image(systemName: riskIcon)
            .font(.title3)
            .foregroundStyle(riskColor)
            .frame(width: 24)
    }

    private var riskIcon: String {
        switch approval.risk {
        case .readonly:   "checkmark.circle.fill"
        case .sideEffect: "exclamationmark.triangle.fill"
        case .dangerous:  "exclamationmark.shield.fill"
        }
    }

    private var riskColor: Color {
        switch approval.risk {
        case .readonly:   .green
        case .sideEffect: .orange
        case .dangerous:  .red
        }
    }
}
