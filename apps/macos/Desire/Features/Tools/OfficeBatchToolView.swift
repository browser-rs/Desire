import SwiftUI

/// 工具箱 ▸ Office 批量转换（v0.8.64 批 5，A7 的 UI 入口补齐——引擎/桥/
/// Agent 工具 0.8.40 已有，只差手动入口）：选文件夹 → 预览可转换文件数
/// → 确认后进 Jobs 队列。执行与台账全在 `OfficeBatchStore`（同一份真相），
/// 这里只做参数收集与预览。
struct OfficeBatchToolView: View {
    @State private var folder: URL?
    @State private var format = "pdf"
    @State private var recursive = false
    @State private var planCount = 0
    @State private var working = false
    @State private var confirmStart = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Folder…")) { chooseFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let folder {
                    Text(verbatim: folder.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .help(folder.path)
                }
            }
            if folder == nil {
                Text(String(localized: "Pick a folder of documents, images, spreadsheets or presentations — each file converts separately into Converted/."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Text(String(localized: "Convert to"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $format) {
                    ForEach(DocumentConvert.formats, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                Toggle(String(localized: "Include subfolders"), isOn: $recursive)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            if let folder {
                Text(String(localized: "\(planCount) file(s) → \(folder.appendingPathComponent("Converted", isDirectory: true).path)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Convert…")) { confirmStart = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(folder == nil || planCount == 0 || working)
                if working {
                    ProgressView().controlSize(.small)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: folder) { _, _ in recompute() }
        .onChange(of: recursive) { _, _ in recompute() }
        .confirmationDialog(
            String(localized: "Convert \(planCount) files to \(format)?"),
            isPresented: $confirmStart) {
            Button(String(localized: "Start conversion"), role: .destructive) { start() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Outputs land in Converted/ next to the folder; existing files are never overwritten. Track progress in Jobs."))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    private func recompute() {
        guard let folder else { planCount = 0; return }
        planCount = OfficeBatchStore.files(in: folder, recursive: recursive).count
    }

    private func start() {
        guard let folder else { return }
        working = true
        let result = OfficeBatchStore.shared.start(
            folder: folder, format: format, recursive: recursive,
            conversationID: nil, report: nil)
        working = false
        switch result {
        case .success(let jobID):
            note = String(localized: "Queued as job \(jobID.uuidString.prefix(8)) — see Jobs for progress.")
        case .failure(let error):
            note = error.message
        }
    }
}
