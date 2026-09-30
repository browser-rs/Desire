import SwiftUI

/// 输入栏左侧的**访问等级**胶囊（参照分级确认设计）：三个等级
/// 变更前确认 → 自动编辑 → 完全访问，Menu 点选即切换（图标+名称+描述+✓）。
/// 完全访问 = 全部工具静默执行；自动编辑 = 页面编辑自动过、系统命令仍管控；
/// 变更前确认 = 副作用工具逐次审批。
struct AgentFullAccessPill: View {
    @ObservedObject var store: AgentSessionStore

    private var level: AgentSessionStore.AccessLevel { store.accessLevel }

    var body: some View {
        Menu {
            ForEach(AgentSessionStore.AccessLevel.allCases, id: \.self) { option in
                Button {
                    store.accessLevel = option
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.icon)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.displayName)
                            Text(option.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if store.accessLevel == option {
                            Spacer(minLength: 12)
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: level.icon)
                    .font(.system(size: 9, weight: .medium))
                Text(level.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(level == .fullAccess ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            // 与输入栏其它控件同高、同描边（此前 20pt 胶囊和 28pt 圆钮混在一起）。
            .frame(height: 26)
            .background(
                Capsule().fill(
                    level == .fullAccess
                        ? Color.orange.opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.6)
                )
            )
            .overlay(
                Capsule().stroke(
                    (level == .fullAccess ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4)),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(.secondary)
        .animation(.hoverFast, value: store.accessLevel)
        .help("Access level — how much the agent may do without asking")
    }
}
