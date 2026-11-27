import AppKit
import SwiftUI

/// 转存结果查看器（v0.8.81 批 3）：大工具结果只把"头 4000 + 尾 1000"留在
/// 上下文里，全文落在 `tool-results/`。这里提供只读查看：按字符偏移切片、
/// 关键字 grep（最多 500 行命中）、Finder 定位。不写文件、不发送网络。
///
/// 读盘在 `.task` 里做一次（文件可达数 MB）；搜索/切片只对已加载字符串做。
struct ToolResultSpillViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loadError: String?
    @State private var query = ""
    @State private var offset = 0
    @State private var isSearching = false

    private static let sliceChars = 12_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search this result"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty }
                Toggle(String(localized: "Grep"), isOn: $isSearching)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if isSearching, !query.isEmpty {
                searchResults
            } else {
                sliceControls
            }
            Spacer(minLength: 0)
            HStack {
                Text(verbatim: "\(text.count) chars")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(String(localized: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 460, idealHeight: 560)
        .task(id: path) { load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "Full tool result"))
                .font(.system(size: 13, weight: .semibold))
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var sliceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(String(localized: "Earlier")) {
                    offset = max(0, offset - Self.sliceChars)
                }
                .disabled(offset <= 0)
                Button(String(localized: "Later")) {
                    offset = min(max(0, text.count - 1), offset + Self.sliceChars)
                }
                .disabled(offset + Self.sliceChars >= text.count)
                Text(String(localized: "Characters"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(offset)–\(min(text.count, offset + Self.sliceChars)) / \(text.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView([.vertical, .horizontal]) {
                Text(sliceText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
        }
    }

    private var searchResults: some View {
        let hits = matchingLines
        return VStack(alignment: .leading, spacing: 4) {
            if hits.isEmpty {
                Text(String(localized: "No matches"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    Text(verbatim: "\(hits.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    Text(String(localized: "matching lines (first 500 shown)"))
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                        HStack(alignment: .top, spacing: 6) {
                            Text(verbatim: "\(hit.line)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing)
                            Text(hit.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
        }
    }

    private var sliceText: String {
        guard !text.isEmpty else {
            return loadError ?? String(localized: "Loading…")
        }
        let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
        let end = text.index(start, offsetBy: min(Self.sliceChars, text.distance(from: start, to: text.endIndex)))
        return String(text[start..<end])
    }

    private var matchingLines: [(line: Int, text: String)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var out: [(Int, String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.lowercased().contains(needle) {
                out.append((index + 1, String(line)))
                if out.count >= 500 { break }
            }
        }
        return out
    }

    private func load() {
        text = ""
        loadError = nil
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            text = String(decoding: data, as: UTF8.self)
            offset = 0
        } catch {
            loadError = error.localizedDescription
        }
    }
}
