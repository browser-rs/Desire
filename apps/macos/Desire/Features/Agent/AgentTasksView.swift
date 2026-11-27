import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @ObservedObject private var batchStore = BatchMediaExportStore.shared
    var onBack: () -> Void

    @State private var isCreating = false
    /// 导入结果提示（v0.8.20）。
    @State private var importNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        weekCalendarSection
                        nextRunsSection
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

    /// 值守周视图（v0.8.83 批 4）：7 天网格里同时看任务运行点与批量/下载
    /// 时段窗口；拥挤日与真实重叠（建议错峰）都标出来，只读不改调度。
    private var weekCalendarSection: some View {
        let week = SurveillanceWeek.build(
            from: Date(),
            days: 7,
            tasks: store.tasks.filter(\.isEnabled).map {
                SurveillanceWeek.TaskInput(name: $0.name,
                                           rule: Self.scheduleRule($0.recurrence))
            },
            windows: weekWindowInputs)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Next 7 days"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !week.conflicts.isEmpty {
                    Text(String(localized: "\(week.conflicts.count) overlap(s)"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(week.days) { day in
                        weekDayCard(day)
                    }
                }
            }
            if !week.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(week.conflicts.prefix(5)) { conflict in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                            Text(String(localized: "\(Self.weekdayFormatter.string(from: conflict.day)) · \(conflict.first) × \(conflict.second) · \(conflict.overlapMinutes) min — consider staggering"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    private func weekDayCard(_ day: SurveillanceWeek.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(Self.weekdayFormatter.string(from: day.date))
                    .font(.system(size: 9.5, weight: .semibold))
                Text(Self.dayFormatter.string(from: day.date))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if day.isCrowded {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .help(String(localized: "Crowded day — many runs and windows overlap"))
                }
            }
            if day.entries.isEmpty {
                Text(verbatim: "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(day.entries.prefix(5)) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(weekTint(entry.kind))
                            .frame(width: 4, height: 4)
                        Text(entry.label)
                            .font(.system(size: 8.5))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if entry.kind == .task {
                            Text(Self.clockFormatter.string(from: entry.start))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("\(entry.label) · \(Self.clockFormatter.string(from: entry.start))–\(Self.clockFormatter.string(from: entry.end))")
                }
                if day.entries.count > 5 {
                    Text(String(localized: "+\(day.entries.count - 5) more"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 96, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(day.hasConflict
                  ? AnyShapeStyle(Color.orange.opacity(0.08))
                  : AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.5))))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(day.hasConflict ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.12),
                        lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(dayAccessibilityLabel(day)))
    }

    private func dayAccessibilityLabel(_ day: SurveillanceWeek.Day) -> String {
        var parts = [
            Self.weekdayFormatter.string(from: day.date),
            Self.dayFormatter.string(from: day.date),
            String(localized: "\(day.entries.count) item(s)")
        ]
        if day.isCrowded { parts.append(String(localized: "crowded")) }
        if day.hasConflict { parts.append(String(localized: "overlapping windows")) }
        for entry in day.entries.prefix(5) {
            parts.append("\(entry.label) \(Self.clockFormatter.string(from: entry.start))")
        }
        return parts.joined(separator: " · ")
    }

    private func weekTint(_ kind: SurveillanceWeek.Kind) -> Color {
        switch kind {
        case .task: appAccent
        case .batch: .orange
        case .downloads: .blue
        }
    }

    private var weekWindowInputs: [SurveillanceWeek.WindowInput] {
        var inputs = batchStore.batches.compactMap { batch -> SurveillanceWeek.WindowInput? in
            guard let window = batch.window else { return nil }
            return .init(label: "Batch · \(batch.folderName)", kind: .batch, window: window)
        }
        if let download = DownloadStore.live?.downloadWindow {
            inputs.append(.init(label: String(localized: "Downloads"),
                                kind: .downloads, window: download))
        }
        return inputs
    }

    private static func scheduleRule(
        _ recurrence: AgentScheduler.ScheduledTask.Recurrence
    ) -> ScheduleDue.Rule {
        switch recurrence {
        case .everyMinutes(let minutes): .everyMinutes(minutes)
        case .daily(let hour, let minute): .daily(hour: hour, minute: minute)
        case .weekly(let weekday, let hour, let minute):
            .weekly(weekday: weekday, hour: hour, minute: minute)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    /// 下一次运行（v0.8.82 批 2）：任务日历的紧凑版——最近 3 次。
    private var nextRunsSection: some View {
        let rows = store.tasks
            .filter(\.isEnabled)
            .map { ($0, store.upcomingRuns(for: $0, count: 3)) }
            .filter { !$0.1.isEmpty }
            .sorted { ($0.1.first ?? .distantFuture) < ($1.1.first ?? .distantFuture) }
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                            .foregroundStyle(appAccent)
                        Text(String(localized: "Next runs"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.0.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 1) {
                                ForEach(Array(row.1.enumerated()), id: \.offset) { _, date in
                                    Text(Self.nextRunFormatter.string(from: date))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    private static let nextRunFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "E HH:mm"
        return f
    }()

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
            reportTemplateDraft = AppPrefs.defaults.string(forKey: "crew.reportTemplate") ?? ""
            showReportTemplateEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Crew Report Template…")
                    .font(.system(size: 11.5))
                Spacer()
                if AppPrefs.defaults.string(forKey: "crew.reportTemplate")?.isEmpty == false {
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
                    AppPrefs.defaults.removeObject(forKey: "crew.reportTemplate")
                    reportTemplateDraft = ""
                }
                Spacer()
                Button(String(localized: "Cancel")) { showReportTemplateEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    let trimmed = reportTemplateDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        AppPrefs.defaults.removeObject(forKey: "crew.reportTemplate")
                    } else {
                        AppPrefs.defaults.set(trimmed, forKey: "crew.reportTemplate")
                    }
                    showReportTemplateEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// 导出/导入任务配置（v0.8.20 替人干活 18）。
    private func exportTasksJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "desire-tasks.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportJSON().write(to: url, atomically: true, encoding: .utf8)
    }

    private func importTasksJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let (added, skipped) = store.importJSON(text)
        importNote = added > 0
            ? String(localized: "Imported \(added) task(s)\(skipped.isEmpty ? "" : ", skipped \(skipped.count) name conflict(s)")")
            : String(localized: "Nothing imported\(skipped.isEmpty ? "" : " — \(skipped.count) name conflict(s)")")
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
            // 任务 JSON 导出/导入（v0.8.20 查缺补漏：桥端点已有、UI 补上）。
            Menu {
                Button(String(localized: "Export Tasks…")) { exportTasksJSON() }
                Button(String(localized: "Import Tasks…")) { importTasksJSON() }
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Share task configs as JSON"))
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
    /// 夜间窗口（v0.8.19）：免打扰时段顺延到窗口结束。
    @State private var deferQuiet = false

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

Toggle(String(localized: "Defer runs inside quiet hours"), isOn: $deferQuiet)
                .font(.system(size: 11))
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
            store.setQuietDeferral(named: name, deferQuiet)
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
    @State private var showRuns = false

    /// 最近一次失败（v0.8.82 批 4）：类别 + 指引，替代只有一行 lastResult。
    private var lastFailure: (category: TaskFailureClassify.Category, message: String)? {
        guard let run = store.runs.first(where: { $0.taskName == task.name }),
              run.success == false || run.status == "failed" || run.status == "missed" else {
            return nil
        }
        let message = run.error ?? task.lastResult ?? ""
        return (TaskFailureClassify.classify(message), message)
    }

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
                if task.deferInQuietHours == true {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(String(localized: "Runs deferred to quiet-hours end"))
                }
                Spacer(minLength: 8)
                Button {
                    showRuns = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Run history"))
                .help(String(localized: "Run history"))
                if let upstream = store.chainPredecessor(of: task.name) {
                    Button {
                        _ = store.continueChain(from: task.name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 9, weight: .bold))
                            Text("Continue")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!task.isEnabled || store.latestSuccessfulOutput(for: upstream) == nil)
                    .opacity(task.isEnabled ? 1 : 0.4)
                    .help("Run this step with \(upstream)'s latest successful output")
                }
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

            let chain = store.chainStatus(startingAt: task.name)
            if chain.path.count > 1 {
                HStack(spacing: 5) {
                    Text(verbatim: chain.path.joined(separator: " → "))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failed = chain.failedStep {
                        Label(String(format: String(localized: "failed at %@"), failed),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                }
                .help("Full chain from this step")
            }

            if let failure = lastFailure, !failure.message.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.category.title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.red)
                        Text(failure.category.hint)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 6) {
                Label(task.recurrenceText, systemImage: "repeat")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
                targetMenu
                retryMenu
                if let chain = task.chainTo {
                    Label(chain, systemImage: "arrow.right.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("After a successful run, fire \(chain) — its prompt can use {{prev.output}}")
                        .lineLimit(1)
                }
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

    /// 任务级重试覆盖（v0.8.81 批 6）：nil = 跟随设置页的全局次数。
    private var retryMenu: some View {
        Menu {
            Button(String(localized: "Follow global setting")) {
                store.setRetryLimit(nil, for: task.id)
            }
            .disabled(task.retryLimit == nil)
            Divider()
            ForEach(0...TaskRetryPolicy.maxRetries, id: \.self) { count in
                Button(count == 0
                       ? String(localized: "No retries")
                       : String(format: String(localized: "%lld retries"), count)) {
                    store.setRetryLimit(count, for: task.id)
                }
                .disabled(task.retryLimit == count)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .medium))
                Text(task.retryLimit.map { "\($0)" } ?? String(localized: "auto"))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Retry limit"))
        .help(String(localized: "Per-task retry limit (global setting is used when auto)"))
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


/// 单任务运行历史（v0.8.82 批 2）：RunRecord 已含 prompt/output/catchUp。
private struct AgentTaskRunsSheet: View {
    @ObservedObject private var store = AgentScheduler.shared
    let task: AgentScheduler.ScheduledTask
    @Environment(\.dismiss) private var dismiss

    private var runs: [AgentScheduler.RunRecord] {
        store.runs.filter { $0.taskName == task.name }.prefix(20).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Run history · \(task.name)"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if runs.isEmpty {
                Text(String(localized: "No runs yet."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon(run))
                                        .font(.system(size: 10))
                                        .foregroundStyle(color(run))
                                    Text(run.status)
                                        .font(.system(size: 10.5, weight: .semibold))
                                    if run.catchUp == true {
                                        Text(String(localized: "caught up"))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(Self.format(run.firedAt))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                if let error = run.error, !error.isEmpty {
                                    Text(error)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                        .lineLimit(3)
                                }
                                if let output = run.output, !output.isEmpty {
                                    Text(output)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(6)
                                        .textSelection(.enabled)
                                }
                                if run.attempts > 1 {
                                    Text(String(format: String(localized: "%lld attempts"), run.attempts))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private func icon(_ run: AgentScheduler.RunRecord) -> String {
        if run.success == true { return "checkmark.circle.fill" }
        if run.success == false || run.status == "failed" || run.status == "missed" {
            return "xmark.circle.fill"
        }
        return "clock"
    }

    private func color(_ run: AgentScheduler.RunRecord) -> Color {
        if run.success == true { return .green }
        if run.success == false || run.status == "failed" || run.status == "missed" {
            return .red
        }
        return .secondary
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func format(_ date: Date) -> String { formatter.string(from: date) }
}
