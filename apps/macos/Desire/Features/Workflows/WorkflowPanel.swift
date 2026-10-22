import SwiftUI
import WebKit

/// 工作流面板（v0.7.29）：录制开关、已存工作流列表、回放（敏感步骤现填值）。
struct WorkflowPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = WorkflowStore.shared
    @ObservedObject private var scheduler = AgentScheduler.shared
    var onClose: () -> Void

    @State private var newName = ""
    @State private var runTarget: Workflow?
    @State private var results: [WorkflowPlayer.StepResult] = []
    @State private var note: String?

    private var activeTab: Tab? {
        TabSessionCoordinator.shared.activeTabManager?.selectedTab
    }
    private var activeURL: String? {
        activeTab.map { $0.browser.webView.url?.absoluteString ?? $0.urlString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            recordingBar
            Divider()
            if store.workflows.isEmpty {
                empty
            } else {
                List {
                    Section(String(localized: "Saved workflows")) {
                        ForEach(store.workflows) { workflow in
                            row(workflow)
                        }
                    }
                    if !results.isEmpty {
                        Section(String(localized: "Last run")) {
                            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                                HStack(spacing: 6) {
                                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(result.ok ? Color.green : Color.red)
                                    Text("#\(result.index + 1) \(result.kind.rawValue)")
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(result.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 520)
        .sheet(item: $runTarget) { workflow in
            WorkflowRunSheet(workflow: workflow) { stepResults in
                results = stepResults
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.badge.play")
                .foregroundStyle(appAccent)
            Text("Web Workflows")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text(String(localized: "Recording on \(store.recordingHost ?? "?") · \(store.pendingSteps.count) step(s)"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    TextField(String(localized: "Name"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button(String(localized: "Stop & Save")) { stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(String(localized: "Cancel")) { cancelRecording() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Text(String(localized: "Record clicks, typing and navigation on this page."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu(String(localized: "Templates")) {
                        ForEach(WorkflowTemplates.all) { template in
                            Button(template.name) { addTemplate(template) }
                                .help(template.detail)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(activeURL == nil)
                    .help("Create a generic workflow for this site")
                    Button(String(localized: "Start Recording")) { startRecording() }
                        .controlSize(.small)
                        .disabled(activeURL == nil)
                }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func row(_ workflow: Workflow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .font(.system(size: 12.5, weight: .medium))
                Text("\(workflow.host) · \(workflow.steps.count) step(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Offer", isOn: Binding(
                get: { workflow.offerOnVisit ?? false },
                set: { store.setOfferOnVisit(workflow.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 10))
            .help("Suggest this workflow when you visit \(workflow.host)")
            Button(String(localized: "Run")) { beginRun(workflow) }
                .controlSize(.small)
            Menu {
                if let scheduled = scheduler.workflowSchedule(for: workflow.id) {
                    Text(String(localized: "Scheduled: \(scheduled.recurrenceText)"))
                    Button(String(localized: "Remove schedule"), role: .destructive) {
                        scheduler.removeWorkflowSchedule(workflow.id)
                        note = nil
                    }
                    Divider()
                }
                Button(String(localized: "Every hour")) {
                    schedule(workflow, .everyMinutes(60))
                }
                Button(String(localized: "Daily at 09:00")) {
                    schedule(workflow, .daily(hour: 9, minute: 0))
                }
                Button(String(localized: "Daily at 18:00")) {
                    schedule(workflow, .daily(hour: 18, minute: 0))
                }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Run this workflow on a schedule (off-screen, no model)")
            Button {
                store.delete(workflow.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No saved workflows")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start recording, perform the steps once, then save.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addTemplate(_ template: WorkflowTemplates.Template) {
        guard let url = activeURL else {
            note = String(localized: "Open a page first.")
            return
        }
        if let workflow = store.addTemplate(template, url: url) {
            note = String(localized: "Added “\(workflow.name)” for \(workflow.host).")
        } else {
            note = String(localized: "Couldn't add the template on this page.")
        }
    }

    private func schedule(_ workflow: Workflow,
                          _ recurrence: AgentScheduler.ScheduledTask.Recurrence) {
        guard !workflow.steps.contains(where: { $0.sensitive }) else {
            note = String(localized: "This workflow has sensitive steps — scheduled runs can't fill values.")
            return
        }
        if let task = scheduler.scheduleWorkflow(workflow, recurrence: recurrence) {
            note = String(localized: "Scheduled “\(workflow.name)” \(task.recurrenceText).")
        }
    }

    private func startRecording() {        guard let url = activeURL, let tab = activeTab else {
            note = String(localized: "Open a page first.")
            return
        }
        store.startRecording(url: url)
        tab.browser.webView.evaluateJavaScript("window.__desireWorkflowRecording = true",
                                               completionHandler: nil)
        note = nil
    }

    private func stopRecording() {
        activeTab?.browser.webView.evaluateJavaScript("window.__desireWorkflowRecording = false",
                                                      completionHandler: nil)
        if store.stopRecording(name: newName) == nil {
            note = String(localized: "Nothing was recorded.")
        } else {
            note = nil
            newName = ""
        }
    }

    private func cancelRecording() {
        activeTab?.browser.webView.evaluateJavaScript("window.__desireWorkflowRecording = false",
                                                      completionHandler: nil)
        store.cancelRecording()
        note = nil
    }

    private func beginRun(_ workflow: Workflow) {
        results = []
        runTarget = workflow
    }
}

/// 回放前收集敏感步骤的值；值只在本次运行内存里，不写回工作流。
private struct WorkflowRunSheet: View {
    let workflow: Workflow
    let onFinish: ([WorkflowPlayer.StepResult]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [UUID: String] = [:]
    @State private var running = false
    @State private var error: String?

    private var sensitiveSteps: [Workflow.Step] {
        workflow.steps.filter(\.sensitive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflow.name)
                .font(.headline)
            Text("\(workflow.host) · \(workflow.steps.count) step(s)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !sensitiveSteps.isEmpty {
                Text("This recording never stored these values — enter them for this run:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sensitiveSteps) { step in
                    TextField(step.note ?? step.selectors.first ?? "Value",
                              text: Binding(get: { values[step.id] ?? "" },
                                            set: { values[step.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(running ? "Running…" : "Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func run() {
        guard let webView = TabSessionCoordinator.shared.activeTabManager?
            .selectedTab?.browser.webView else {
            error = String(localized: "No active tab.")
            return
        }
        let missing = WorkflowLogic.missingSensitiveValues(workflow, values: values)
        guard missing.isEmpty else {
            error = String(localized: "Fill every value first.")
            return
        }
        running = true
        Task { @MainActor in
            let result = await WorkflowPlayer.run(workflow, values: values, in: webView)
            running = false
            onFinish(result.results)
            dismiss()
        }
    }
}
