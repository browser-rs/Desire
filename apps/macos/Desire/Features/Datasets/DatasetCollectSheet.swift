import AppKit
import SwiftUI
import WebKit

/// 列表 → 表格采集（v0.8.2）：填选择器 → 抓取 → CSV 落 Downloads。
/// 采集是确定性的（不逐行调模型），产物进 Jobs 并有回执。
struct DatasetCollectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var rowSelector = ""
    @State private var fieldsText = "title=.title\nprice=.price"
    @State private var pagination: DatasetSpec.Pagination = .none
    @State private var nextSelector = ""
    @State private var urlTemplate = ""
    @State private var maxPages = 10
    @State private var fileName = ""
    @State private var running = false
    @State private var resultText: String?
    @State private var resultPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collect Table")
                    .font(.system(size: 15, weight: .semibold))
                Text("Deterministic DOM collection → CSV in Downloads. No per-row model calls.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("URL").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("https://…", text: $url)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Row selector").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField(".item", text: $rowSelector)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("Pagination").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Picker("", selection: $pagination) {
                        ForEach(DatasetSpec.Pagination.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if pagination == .nextButton {
                    GridRow {
                        Text("Next selector").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        TextField(".next", text: $nextSelector)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                if pagination == .urlTemplate {
                    GridRow {
                        Text("URL template").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        TextField("https://…/page/{page}", text: $urlTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                GridRow {
                    Text("Max pages").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Stepper("\(maxPages)", value: $maxPages, in: 1...50)
                }
                GridRow {
                    Text("File name").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("dataset", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Fields (one key=selector per line)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextEditor(text: $fieldsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 80)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor)))
            }

            if let resultText {
                Text(resultText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                if let resultPath {
                    Button(String(localized: "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: resultPath)])
                    }
                    .buttonStyle(.bordered)
                }
                Button(String(localized: "Collect")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || url.trimmingCharacters(in: .whitespaces).isEmpty
                              || rowSelector.trimmingCharacters(in: .whitespaces).isEmpty
                              || DatasetSpec.parseFields(fieldsText).isEmpty)
                // 定时采集（v0.8.20 融合 12）：先存命名规格，再挂调度。
                Menu {
                    Button(String(localized: "Every hour")) {
                        scheduleSpec(.everyMinutes(60))
                    }
                    Button(String(localized: "Daily at 09:00")) {
                        scheduleSpec(.daily(hour: 9, minute: 0))
                    }
                    Button(String(localized: "Daily at 18:00")) {
                        scheduleSpec(.daily(hour: 18, minute: 0))
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty
                          || rowSelector.trimmingCharacters(in: .whitespaces).isEmpty
                          || DatasetSpec.parseFields(fieldsText).isEmpty)
                .help(String(localized: "Save as a named spec and schedule periodic collection"))
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear {
            if url.isEmpty {
                url = TabSessionCoordinator.shared.activeTabManager?.selectedTab?
                    .browser.webView.url?.absoluteString ?? ""
            }
        }
    }

    /// 保存命名规格 + 挂 builtin 调度（v0.8.20 融合 12）。
    private func scheduleSpec(_ recurrence: AgentScheduler.ScheduledTask.Recurrence) {
        let fields = DatasetSpec.parseFields(fieldsText)
        let spec = DatasetSpec(
            startURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            rowSelector: rowSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: fields,
            pagination: pagination,
            nextSelector: nextSelector.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nextSelector,
            urlTemplate: urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : urlTemplate,
            maxPages: maxPages,
            maxRows: 2000)
        let name = fileName.trimmingCharacters(in: .whitespaces).isEmpty
            ? (URL(string: spec.startURL)?.host ?? "dataset")
            : fileName.trimmingCharacters(in: .whitespaces)
        let named = DatasetSpecStore.shared.save(name: name, spec: spec)
        let kind = "dataset:\(named.id.uuidString)"
        if AgentScheduler.shared.addBuiltin(name: "数据集采集：\(name)",
                                            recurrence: recurrence, kind: kind) != nil {
            resultText = String(localized: "Scheduled: \(recurrenceText) — named spec \(name)")
        } else {
            resultText = String(localized: "Schedule failed (name already in use?)")
        }
    }

    private var recurrenceText: String {
        // 占位文案由 addBuiltin 展示任务名即可——这里给简短说明。
        String(localized: "see Scheduled Tasks")
    }

    private func start() {
        let fields = DatasetSpec.parseFields(fieldsText)
        let spec = DatasetSpec(
            startURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            rowSelector: rowSelector.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: fields,
            pagination: pagination,
            nextSelector: nextSelector.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nextSelector,
            urlTemplate: urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : urlTemplate,
            maxPages: maxPages,
            maxRows: 2000)
        running = true
        resultText = nil
        resultPath = nil
        Task { @MainActor in
            let result = await DatasetCollector.collect(spec, fileName: fileName)
            running = false
            if result.ok {
                resultPath = result.path
                resultText = String(localized: "Collected \(result.rowCount) row(s) from \(result.pageCount) page(s).")
            } else {
                resultText = String(localized: "Failed: ") + result.errors.joined(separator: "; ")
            }
        }
    }
}
