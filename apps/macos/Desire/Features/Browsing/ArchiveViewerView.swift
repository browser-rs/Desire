import SwiftUI

/// 压缩包直开查看器（v0.8.12 旗舰 C，7）：zip 拖入 → 条目树（名称/大小），
/// 点文本/图片条目直接预览（解到临时文件）；工具条"解压到…"（8）。
struct ArchiveViewerView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var entries: [ArchiveKit.Entry] = []
    @State private var loadError: String?
    @State private var extracting = false
    @State private var statusNote: String?
    @State private var previewTempURL: URL?
    @State private var previewText: String?
    /// 解压所选（v0.8.26）：勾选的条目路径。
    @State private var selection: Set<String> = []

    private var totalCount: Int { entries.filter { !$0.isDirectory }.count }
    private var totalBytes: Int64 { entries.reduce(0) { $0 + max(0, $1.sizeBytes) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(loadError)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: load)
        .onDisappear { cleanupPreview() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !selection.isEmpty {
                Button {
                    extractSelectedTo()
                } label: {
                    Label(String(localized: "Extract Selected (\(selection.count))"),
                          systemImage: "checkmark.square")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .disabled(extracting)
            }
            Button {
                extractTo()
            } label: {
                Label(String(localized: "Extract to…"), systemImage: "archivebox")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(extracting || entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    row(entry)
                }
            }
        }
        .overlay(alignment: .center) {
            if extracting {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Extracting…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            }
        }
    }

    private func row(_ entry: ArchiveKit.Entry) -> some View {
        HStack(spacing: 8) {
            let depth = entry.path.split(separator: "/").count - 1
            if !entry.isDirectory {
                Button {
                    if selection.contains(entry.path) {
                        selection.remove(entry.path)
                    } else {
                        selection.insert(entry.path)
                    }
                } label: {
                    Image(systemName: selection.contains(entry.path)
                          ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11))
                        .foregroundStyle(selection.contains(entry.path)
                                         ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Select for extraction"))
            }
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(entry.isDirectory ? Color.secondary : appAccent)
                .padding(.leading, CGFloat(depth) * 16)
            Text((entry.path as NSString).lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.isDirectory {
                Spacer()
            } else {
                Spacer(minLength: 8)
                Text(ArchiveKit.sizeText(entry.sizeBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if previewable(entry.path) {
                    Button(String(localized: "Preview")) {
                        preview(entry)
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
        .contentShape(Rectangle())
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if !entries.isEmpty {
                Text("\(totalCount) files · \(ArchiveKit.sizeText(totalBytes))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if extracting {
                ProgressView().controlSize(.small)
            }
            if let statusNote {
                Text(statusNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(appAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 动作

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = ArchiveKit.list(archiveURL: fileURL)
            DispatchQueue.main.async {
                if let list, !list.isEmpty {
                    entries = list.sorted { $0.path < $1.path }
                } else {
                    loadError = String(localized: "Not a readable zip archive (rar/7z are not supported).")
                }
            }
        }
    }

    private func previewable(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["txt", "md", "json", "log", "xml", "csv", "html"].contains(ext)
            || ["png", "jpg", "jpeg", "gif"].contains(ext)
    }

    /// 单文件预览：unzip -p 到临时文件（文本直接显示；图片打开预览窗）。
    private func preview(_ entry: ArchiveKit.Entry) {
        cleanupPreview()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", fileURL.path, entry.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try? process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard process.terminationStatus == 0, !data.isEmpty else {
                    flash(String(localized: "Could not extract this entry"))
                    return
                }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif"].contains(ext) {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("archive-preview.\(ext)")
                    try? data.write(to: tmp)
                    previewTempURL = tmp
                    NSWorkspace.shared.open(tmp)
                } else if let text = String(data: data, encoding: .utf8) {
                    previewText = String(text.prefix(8_000))
                } else {
                    flash(String(localized: "Binary entry — use Extract to…"))
                }
            }
        }
    }

    private func cleanupPreview() {
        if let url = previewTempURL {
            try? FileManager.default.removeItem(at: url)
            previewTempURL = nil
        }
        previewText = nil
    }

    /// 解压所选（v0.8.26）：只解勾选的条目 → 通知 + 回执。
    private func extractSelectedTo() {
        guard !selection.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Extract Selected")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        extracting = true
        let archive = fileURL
        let chosen = selection.sorted()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try ArchiveKit.extract(archiveURL: archive, to: dest, entries: chosen)
                DispatchQueue.main.async {
                    extracting = false
                    selection.removeAll()
                    flash(String(localized: "Extracted \(result.files) file(s), \(ArchiveKit.sizeText(result.bytes)) → \(dest.lastPathComponent)"))
                    ProactiveNotificationStore.shared.deliver(
                        title: String(localized: "Archive extracted: \(archive.lastPathComponent)"),
                        body: String(localized: "\(result.files) selected file(s) → \(dest.path)"),
                        tier: .routine)
                }
            } catch {
                DispatchQueue.main.async {
                    extracting = false
                    flash(String(localized: "Extract failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// 解压到…（8）：选目录 → 后台 ditto → 通知 + 回执。
    private func extractTo() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Extract to…")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        extracting = true
        let archive = fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try ArchiveKit.extract(archiveURL: archive, to: dest)
                DispatchQueue.main.async {
                    extracting = false
                    flash(String(localized: "Extracted \(result.files) file(s), \(ArchiveKit.sizeText(result.bytes)) → \(dest.lastPathComponent)"))
                    ProactiveNotificationStore.shared.deliver(
                        title: String(localized: "Archive extracted: \(archive.lastPathComponent)"),
                        body: String(localized: "\(result.files) file(s), \(ArchiveKit.sizeText(result.bytes)) → \(dest.path)"),
                        tier: .routine)
                }
            } catch {
                DispatchQueue.main.async {
                    extracting = false
                    flash(String(localized: "Extract failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func flash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusNote == text { statusNote = nil }
        }
    }
}
