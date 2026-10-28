import SwiftUI

/// 定时任务管理页（Agent 窗口侧栏"任务"目的地，2026-10-10）。
/// 数据与管理 API 全部来自 `AgentScheduler`（与设置页 ScheduledTasksSection
/// 同源）：开关、目标窗口、立即执行、删除。任务的创建走 Agent 的
/// scheduleTask 工具（或设置页提示的口令），这里不重复造创建表单。
struct AgentTasksView: View {
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E"
        return f
    }()
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = AgentScheduler.shared
    var onBack: () -> Void

    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        runTimeline
                        ForEach(store.tasks) { task in
                            AgentTaskCard(task: task)
                        }
                    }
                    .padding(12)
                }
            }
            crewReportTemplateSection
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isCreating) {
            AgentTaskEditorSheet()
        }
    }

    // MARK: - 运行时间线（v0.8.18 基础件 8）+ crew 报告模板（基础件 6）

    /// 最近 7 天运行分布：手工条形（成功/失败双色），RunRecord 已有数据。
    private var runTimeline: some View {
        let calendar = Calendar.current
        let days = (0..<7).reversed().map { offset -> (label: String, ok: Int, fail: Int) in
            let day = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let dayRuns = store.runs.filter { calendar.isDate($0.firedAt, inSameDayAs: day) }
            let label = Self.weekdayFormatter.string(from: day)
            // 口径对齐 store（AgentScheduler 348 行）：success==false 或
            // status failed/missed 都算失败。
            return (label,
                    dayRuns.filter { $0.success == true }.count,
                    dayRuns.filter { $0.success == false || $0.status == "failed" || $0.status == "missed" }.count)
        }
        let peak = max(1, days.map { max($0.ok, $0.fail) }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(days, id: \.label) { day in
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 2) {
                        if day.ok > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(appAccent.opacity(0.75))
                                .frame(width: 8, height: CGFloat(day.ok) / CGFloat(peak) * 34 + 3)
                        }
                        if day.fail > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red.opacity(0.6))
                                .frame(width: 8, height: CGFloat(day.fail) / CGFloat(peak) * 34 + 3)
                        }
                        if day.ok == 0 && day.fail == 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 8, height: 3)
                        }
                    }
                    .frame(height: 37, alignment: .bottom)
                    Text(day.label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(localized: "Last 7 days"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(appAccent.opacity(0.75)).frame(width: 5, height: 5)
                    Text(String(localized: "ok"))
                    Circle().fill(Color.red.opacity(0.6)).frame(width: 5, height: 5)
                    Text(String(localized: "failed"))
                }
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    /// crew 报告模板编辑（v0.8.18 基础件 6）：占位符
    /// {{objective}}/{{done}}/{{failed}}/{{duration}}/{{usage}}/{{tasks}}；
    /// 空 = 内置结构。
    @State private var reportTemplateDraft = ""
    @State private var showReportTemplateEditor = false

    private var crewReportTemplateSection: some View {
        Button {
            reportTemplateDraft = UserDefaults.standard.string(forKey: "crew.reportTemplate") ?? ""
            showReportTemplateEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Crew Report Template…")
                    .font(.system(size: 11.5))
                Spacer()
                if UserDefaults.standard.string(forKey: "crew.reportTemplate")?.isEmpty == false {
                    Text(String(localized: "customized"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(appAccent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showReportTemplateEditor) {
            crewTemplateEditor
        }
    }

    private var crewTemplateEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crew Report Template")
                .font(.system(size: 13, weight: .semibold))
            Text(String(localized: "Placeholders: {{objective}} {{done}} {{failed}} {{duration}} {{usage}} and {{tasks}} (per-task sections). Empty = built-in structure."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextEditor(text: $reportTemplateDraft)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 420, height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Button(String(localized: "Reset to Built-in")) {
                    UserDefaults.standard.removeObject(forKey: "crew.reportTemplate")
                    reportTemplateDraft = ""
                }
                Spacer()
                Button(String(localized: "Cancel")) { showReportTemplateEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    let trimmed = reportTemplateDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "crew.reportTemplate")
                    } else {
                        UserDefaults.standard.set(trimmed, forKey: "crew.reportTemplate")
                    }
                    showReportTemplateEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
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
            HoverIcon(systemName: "plus.bubble", action: { isCreating = true }, help: "New Task")
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

/// 新建任务表单（任务页头部 + 号）：名称 + 提示词 + 周期两档
/// （每 N 分钟 / 每天 HH:MM）。目标窗口创建后按卡片上的选择器改
/// （默认跟随最新窗口）。与 AgentScheduler.add 同一条写入路径。
private struct AgentTaskEditorSheet: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AgentScheduler.shared

    @State private var name = ""
    @State private var prompt = ""
    /// false = 每 N 分钟；true = 每天 HH:MM。
    @State private var isDaily = false
    @State private var minutesText = "30"
    @State private var hourText = "9"
    @State private var minuteText = "0"
    @State private var failureText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("New Task")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Text("Prompt")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(height: 84)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )

                Picker(String(localized: "Interval"), selection: $isDaily) {
                    Text("Minutes").tag(false)
                    Text("Daily").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if isDaily {
                    HStack(spacing: 8) {
                        TextField("9", text: $hourText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 56)
                        Text("hour")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("0", text: $minuteText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 56)
                        Text("minute")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("30", text: $minutesText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 72)
                        Text("Minutes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if let failureText {
                    Text(failureText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Save")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
                .font(.system(size: 12))
            }
            .padding(14)
        }
        .frame(width: 400)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let recurrence: AgentScheduler.ScheduledTask.Recurrence
        if isDaily {
            guard let hour = Int(hourText), (0...23).contains(hour),
                  let minute = Int(minuteText), (0...59).contains(minute) else {
                failureText = "0–23 / 0–59"
                return
            }
            recurrence = .daily(hour: hour, minute: minute)
        } else {
            guard let minutes = Int(minutesText), minutes >= 1 else {
                failureText = "≥ 1"
                return
            }
            recurrence = .everyMinutes(minutes)
        }
        if store.add(name: name, prompt: prompt, recurrence: recurrence) != nil {
            dismiss()
        }
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
