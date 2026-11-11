import AppKit
import SwiftUI

/// 批量纯工具页（v0.8.51 批 4）：选文件/文件夹 → 正则替换 / 哈希 /
/// 编码转换 → 逐文件进 Jobs。执行在 `BatchToolStore`，这里只有表单。
struct BatchToolsView: View {
    @StateObject private var store = BatchToolStore.shared
    @State private var action: BatchToolAction = .regexReplace
    @State private var files: [URL] = []
    @State private var pattern = ""
    @State private var template = ""
    @State private var caseInsensitive = false
    @State private var multiline = false
    @State private var algorithm: ToolsCrypto.Algorithm = .sha256
    @State private var fromEncoding = "utf-8"
    @State private var toEncoding = "utf-8"
    @State private var textEncoding = "utf-8"
    @State private var outputDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(String(localized: "Action"), selection: $action) {
                ForEach(BatchToolAction.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            fileSection
            optionsSection
            outputSection
            runSection

            if store.isRunning || store.progress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: store.progress)
                        .controlSize(.small)
                    Text(store.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !store.summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Results"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(store.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 文件

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(String(localized: "Add Files…")) { pickFiles() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Add Folder…")) { pickFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !files.isEmpty {
                    Text(verbatim: "\(files.count) / \(BatchToolCore.maxFiles)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Clear")) { files = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if files.isEmpty {
                Text(String(localized: "Add files or a folder. Source files are never modified."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text(files.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
                     + (files.count > 4 ? "…" : ""))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        merge(panel.urls)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        merge(children.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        })
    }

    private func merge(_ urls: [URL]) {
        var seen = Set(files.map(\.path))
        for url in urls where !seen.contains(url.path) {
            files.append(url)
            seen.insert(url.path)
            if files.count >= BatchToolCore.maxFiles { break }
        }
    }

    // MARK: - 参数

    @ViewBuilder
    private var optionsSection: some View {
        switch action {
        case .regexReplace:
            VStack(alignment: .leading, spacing: 8) {
                ToolEditor(title: String(localized: "Pattern"), text: $pattern,
                           height: 56, placeholder: "\\s+")
                ToolEditor(title: String(localized: "Replacement"), text: $template,
                           height: 56, placeholder: "$1")
                HStack(spacing: 14) {
                    ToolToggle(title: String(localized: "Case insensitive"),
                               isOn: $caseInsensitive)
                    ToolToggle(title: String(localized: "Multiline"), isOn: $multiline)
                    Spacer()
                    encodingPicker(String(localized: "Text encoding"), selection: $textEncoding)
                }
            }
        case .hash:
            HStack(spacing: 10) {
                Picker(String(localized: "Algorithm"), selection: $algorithm) {
                    ForEach(ToolsCrypto.Algorithm.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
            }
        case .encoding:
            HStack(spacing: 10) {
                encodingPicker(String(localized: "From"), selection: $fromEncoding)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                encodingPicker(String(localized: "To"), selection: $toEncoding)
                Spacer()
            }
        }
    }

    private func encodingPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(BatchToolCore.encodingNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .frame(maxWidth: 220)
    }

    // MARK: - 输出目录

    private var outputSection: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Output Folder…")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK else { return }
                outputDirectory = panel.url
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let outputDirectory {
                Text(outputDirectory.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(String(localized: "Clear")) { self.outputDirectory = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "Output goes next to each source file with a suffix; sources are never modified."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 执行

    private var canRun: Bool {
        guard !files.isEmpty, !store.isRunning else { return false }
        if action == .regexReplace { return !pattern.isEmpty }
        return true
    }

    private var runSection: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Run Batch")) {
                var options = BatchToolOptions()
                options.pattern = pattern
                options.template = template
                options.caseInsensitive = caseInsensitive
                options.multiline = multiline
                options.algorithm = algorithm
                options.fromEncoding = fromEncoding
                options.toEncoding = toEncoding
                options.textEncoding = textEncoding
                options.outputDirectory = outputDirectory
                store.start(action: action, files: files, options: options)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canRun)

            if store.isRunning {
                Button(String(localized: "Cancel")) { store.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if action == .hash {
                Text(String(localized: "Hash runs do not write files; digests appear in the results and in Jobs."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
