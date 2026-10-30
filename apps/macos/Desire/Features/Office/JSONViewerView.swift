import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// JSON 查看器（v0.8.26 办公增强，用户点名）：打开 .json/.jsonl/.ndjson 文件——
/// 语法着色、格式化 / 压缩 / 键排序、缩进档位、查找、复制、保存（先留 .bak）、
/// 导出 CSV / Excel。解析与转换全部走 `JSONFormatterCore`（与 Agent/桥同源）。
struct JSONViewerView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var rawText = ""
    @State private var output = ""
    @State private var errorText: String?
    @State private var errorLocation = ""
    @State private var isLoading = true
    @State private var isJSONL = false
    @State private var indent = 2
    @State private var sortKeys = false
    @State private var minified = false
    @State private var showFind = false
    @State private var findText = ""
    @State private var findMatches: [NSRange] = []
    @State private var findIndex = 0
    @State private var flashNote: String?
    @State private var textViewRef = NSTextView()
    /// 着色后的文本（只在格式化/加载后重建，避免每次 body 重算 token）。
    @State private var rendered = NSAttributedString()

    private var byteCount: Int { output.utf8.count }
    private var lineCount: Int { output.isEmpty ? 0 : output.components(separatedBy: "\n").count }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showFind { findBar }
            if let errorText {
                errorBanner(errorText)
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JSONTextView(text: rendered, textViewRef: textViewRef)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: load)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
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
            Button(String(localized: "Format")) { reformat(minify: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(String(localized: "Minify")) { reformat(minify: true) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Toggle(String(localized: "Sort Keys"), isOn: $sortKeys)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: sortKeys) { _, _ in reformat(minify: minified) }
            Picker("", selection: $indent) {
                Text("2").tag(2)
                Text("4").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 64)
            .labelsHidden()
            .onChange(of: indent) { _, _ in reformat(minify: minified) }
            toolButton("magnifyingglass", help: String(localized: "Find (⌘F)")) {
                showFind.toggle()
            }
            toolButton("doc.on.doc", help: String(localized: "Copy")) { copyAll() }
            Menu {
                Button(String(localized: "Export CSV…")) { exportCSV() }
                Button(String(localized: "Export Excel (.xlsx)…")) { exportExcel() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help(String(localized: "Export"))
            Button(String(localized: "Save")) { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(errorText != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toolButton(_ icon: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(String(localized: "Find in JSON"), text: $findText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { findNext() }
                .onChange(of: findText) { _, _ in runFind() }
            Text(findMatches.isEmpty ? "" : "\(findIndex + 1)/\(findMatches.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button { findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
            Button { findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
            Button { showFind = false; findText = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .lineLimit(3)
            if !errorLocation.isEmpty {
                Text(errorLocation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let flashNote {
                Text(flashNote).foregroundStyle(appAccent)
            } else {
                Text(String(localized: "\(byteCount) bytes · \(lineCount) lines"))
                    .monospacedDigit()
                if isJSONL { Text("JSONL") }
                if errorText == nil {
                    Label(String(localized: "Valid JSON"), systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    Label(String(localized: "Invalid JSON"), systemImage: "xmark.seal")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(fileURL.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - 数据

    private func load() {
        let url = fileURL
        Task { @MainActor in
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            isLoading = false
            guard let data, let text = String(data: data, encoding: .utf8) else {
                errorText = String(localized: "Could not read the file as UTF-8 text.")
                return
            }
            rawText = text
            isJSONL = ["jsonl", "ndjson", "jsonlines"].contains(url.pathExtension.lowercased())
                || JSONFormatterCore.looksLikeJSONL(text)
            reformat(minify: false)
        }
    }

    private func reformat(minify: Bool) {
        minified = minify
        let text = rawText
        switch JSONFormatterCore.format(text, indent: indent, sortKeys: sortKeys,
                                        minify: minify, jsonl: isJSONL) {
        case .success(let formatted):
            output = formatted
            errorText = nil
            errorLocation = ""
        case .failure(let failure):
            output = text
            errorText = failure.message
            errorLocation = failure.line > 0
                ? String(localized: "line \(failure.line), column \(failure.column)") : ""
        }
        rendered = JSONTextView.attributed(output.isEmpty ? rawText : output)
        if showFind { runFind() }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.isEmpty ? rawText : output, forType: .string)
        flash(String(localized: "Copied"))
    }

    private func save() {
        guard errorText == nil else { return }
        let fm = FileManager.default
        let backup = fileURL.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: fileURL, to: backup)
        do {
            try output.write(to: fileURL, atomically: true, encoding: .utf8)
            flash(String(localized: "Saved (backup: \(backup.lastPathComponent))"))
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
        }
    }

    private func exportCSV() {
        guard let object = parsedObject(), let csv = JSONFormatterCore.csv(from: object) else {
            flash(String(localized: "This JSON has no tabular shape (array of objects/arrays)."))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try csv.write(to: dest, atomically: true, encoding: .utf8)
            flash(String(localized: "Exported → \(dest.lastPathComponent)"))
        } catch {
            flash(String(localized: "Export failed: \(error.localizedDescription)"))
        }
    }

    private func exportExcel() {
        guard let object = parsedObject(), let table = JSONFormatterCore.table(from: object) else {
            flash(String(localized: "This JSON has no tabular shape (array of objects/arrays)."))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".xlsx"
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let ok = SpreadsheetXLSXWriter.write(rows: [table.header] + table.rows,
                                             sheetName: "JSON", to: dest)
        flash(ok ? String(localized: "Exported → \(dest.lastPathComponent)")
                 : String(localized: "Export failed"))
    }

    private func parsedObject() -> Any? {
        switch JSONFormatterCore.parse(output.isEmpty ? rawText : output) {
        case .success(let object): return object
        case .failure: return nil
        }
    }

    private func flash(_ text: String) {
        flashNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if flashNote == text { flashNote = nil }
        }
    }

    // MARK: - 查找

    private func runFind() {
        textViewRef.usesFindBar = true
        let haystack = (output.isEmpty ? rawText : output) as NSString
        let needle = findText
        guard !needle.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor <= haystack.length {
            let range = haystack.range(of: needle, options: [.caseInsensitive],
                                       range: NSRange(location: cursor, length: haystack.length - cursor))
            guard range.location != NSNotFound else { break }
            ranges.append(range)
            cursor = range.location + max(1, range.length)
            if ranges.count >= 500 { break }
        }
        findMatches = ranges
        findIndex = 0
        selectCurrent()
    }

    private func findNext() {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
        selectCurrent()
    }

    private func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
        selectCurrent()
    }

    private func selectCurrent() {
        guard findMatches.indices.contains(findIndex) else { return }
        let range = findMatches[findIndex]
        textViewRef.setSelectedRange(range)
        textViewRef.scrollRangeToVisible(range)
    }
}

// MARK: - 只读文本视图

/// 只读 NSTextView 宿主：一次设置 attributed 文本（token 上色），支持选择/复制/⌘F。
private struct JSONTextView: NSViewRepresentable {
    let text: NSAttributedString
    let textViewRef: NSTextView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textView = textViewRef
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard textView.textStorage?.string != text.string else { return }
        textView.textStorage?.setAttributedString(text)
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        let length = (text as NSString).length
        for token in JSONSyntaxHighlightCore.tokens(in: text) {
            guard token.location >= 0, token.location + token.length <= length else { continue }
            let color: NSColor
            switch token.kind {
            case .key: color = .systemBlue
            case .string: color = .systemGreen
            case .number: color = .systemOrange
            case .literal: color = .systemPurple
            }
            result.addAttribute(.foregroundColor, value: color,
                                range: NSRange(location: token.location, length: token.length))
        }
        return result
    }
}
