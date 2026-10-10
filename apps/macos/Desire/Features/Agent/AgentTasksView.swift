import SwiftUI

/// 定时任务管理页（Agent 窗口侧栏"任务"目的地，2026-10-10）。
/// 数据与管理 API 全部来自 `AgentScheduler`（与设置页 ScheduledTasksSection
/// 同源）：开关、目标窗口、立即执行、删除。任务的创建走 Agent 的
/// scheduleTask 工具（或设置页提示的口令），这里不重复造创建表单。
struct AgentTasksView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = AgentScheduler.shared
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.tasks) { task in
                            AgentTaskCard(task: task)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Tasks")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(store.tasks.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .frame(width: 48, height: 48)
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            Text("No scheduled tasks yet.")
                .font(.system(size: 13, weight: .semibold))
            Text("Prompts that re-run automatically while the app is open. Ask the agent to create one, e.g. 「每天 9 点总结我的待办」.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 单条任务卡：开关 + 名称 + 提示词预览 + 周期/目标/最近结果 + 立即执行 + 删除。
private struct AgentTaskCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = AgentScheduler.shared
    let task: AgentScheduler.ScheduledTask

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { store.setEnabled($0, for: task.id) }
                ))
                .labelsHidden()
                .scaleEffect(0.8, anchor: .leading)
                Text(task.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    _ = store.fireNow(named: task.name)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Run now")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(appAccent.opacity(0.12)))
                    .foregroundStyle(appAccent)
                }
                .buttonStyle(.plain)
                .disabled(!task.isEnabled)
                .opacity(task.isEnabled ? 1 : 0.4)
                .help("Run now")
                Button {
                    store.remove(task.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }

            Text(task.prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Label(task.recurrenceText, systemImage: "repeat")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
                targetMenu
                if let result = task.lastResult {
                    Text(result)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(result == "delivered" ? .green : .orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    /// 目标选择器（与设置页 ScheduledTaskRow 同语义）：胶囊 chip 显示当前
    /// 目标，点开列全部活会话 + "跟随最新窗口"。
    private var targetMenu: some View {
        Menu {
            Button(String(localized: "Newest Window")) {
                store.setTarget(nil, for: task.id)
            }
            .disabled(task.targetSessionID == nil)
            Divider()
            ForEach(AgentScheduler.shared.liveSessions()) { entry in
                Button(entry.displayLabel) {
                    store.setTarget(entry.id, for: task.id)
                }
                .disabled(task.targetSessionID == entry.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.landscape.rotate")
                    .font(.system(size: 9, weight: .medium))
                Text(targetChipLabel)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .foregroundStyle(.primary)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(String(localized: "Which window's agent receives this task"))
    }

    private var targetChipLabel: String {
        if task.targetSessionID != nil {
            return store.targetLabel(for: task.id) ?? String(localized: "Closed Window")
        }
        return String(localized: "Newest Window")
    }
}
