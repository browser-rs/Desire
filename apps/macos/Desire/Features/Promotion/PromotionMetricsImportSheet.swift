import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 指标导入（v0.8.3）：平台报表 CSV/TSV → 帖子指标快照。
/// 仅在无 DPP 适配/无采集端点时兜底；按 URL/标题匹配，同日快照覆盖不堆叠。
struct PromotionMetricsImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = PromotionStore.shared

    private struct Match: Identifiable {
        let id = UUID()
        let row: PromotionMetricsImport.Row
        let post: PromotionPost?
    }

    /// 直通路径（v0.8.12 融合 15）：从"已打开的表格标签"导入时由调用方传入，
    /// onAppear 直接加载，跳过文件选择器。
    var initialFileURL: URL? = nil
    @State private var fileName = ""
    @State private var result: PromotionMetricsImport.ParseResult?
    @State private var matches: [Match] = []
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(appAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Import Metrics"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "CSV/TSV export from a platform dashboard. Matched by URL first, then exact title; same-day rows overwrite instead of stacking."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Choose File…")) { chooseFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if !fileName.isEmpty {
                Text(fileName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
            if let result {
                HStack(spacing: 10) {
                    Text(String(localized: "\(result.rows.count) rows"))
                    Text(String(localized: "delimiter: \(result.delimiter)"))
                    Text(String(localized: "\(matchedCount) matched"))
                        .foregroundStyle(matchedCount > 0 ? Color.secondary : Color.orange)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                ForEach(result.errors, id: \.self) { err in
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        headerRow
                        ForEach(matches.prefix(30)) { match in
                            rowView(match)
                        }
                    }
                }
                .frame(maxHeight: 260)
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "No file selected."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Import Matched")) { importMatched() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(matchedCount == 0)
            }
        }
        .padding(16)
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let initialFileURL, result == nil {
                load(initialFileURL)
            }
        }
    }

    private var matchedCount: Int { matches.filter { $0.post != nil }.count }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Match")).frame(width: 170, alignment: .leading)
            Text(String(localized: "Views")).frame(width: 60, alignment: .trailing)
            Text(String(localized: "Likes")).frame(width: 50, alignment: .trailing)
            Text(String(localized: "Comments")).frame(width: 60, alignment: .trailing)
            Text(String(localized: "Date")).frame(width: 80, alignment: .leading)
            Spacer()
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func rowView(_ match: Match) -> some View {
        HStack(spacing: 8) {
            Text(match.post?.title ?? match.row.title ?? match.row.url ?? "—")
                .font(.system(size: 10.5))
                .foregroundStyle(match.post == nil ? .orange : .primary)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            Text(match.row.views.map { String($0) } ?? "—")
                .frame(width: 60, alignment: .trailing)
            Text(match.row.likes.map { String($0) } ?? "—")
                .frame(width: 50, alignment: .trailing)
            Text(match.row.comments.map { String($0) } ?? "—")
                .frame(width: 60, alignment: .trailing)
            Text(match.row.date.map(Self.shortDate) ?? "—")
                .frame(width: 80, alignment: .leading)
            if match.post == nil {
                Text(String(localized: "unmatched"))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Metrics")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            load(url)
        }
    }

    private func load(_ url: URL) {
        error = nil
        message = nil
        result = nil
        matches = []
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else {
            error = String(localized: "Could not read the file as text. Export it as UTF-8 CSV/TSV.")
            return
        }
        fileName = url.lastPathComponent
        let parsed = PromotionMetricsImport.parse(text: text)
        result = parsed
        matches = parsed.rows.map {
            Match(row: $0, post: PromotionMetricsImport.match(row: $0, posts: store.posts))
        }
        if !parsed.errors.isEmpty {
            error = parsed.errors.joined(separator: "\n")
        }
    }

    private func importMatched() {
        var imported = 0
        for match in matches {
            guard let post = match.post else { continue }
            _ = store.recordImportedMetrics(
                postID: post.id,
                views: match.row.views,
                likes: match.row.likes,
                comments: match.row.comments,
                at: match.row.date ?? Date())
            imported += 1
        }
        // 重新匹配一次（导入只改指标，不影响匹配；保持列表稳定）。
        message = String(localized: "Imported \(imported) rows. Same-day snapshots were replaced, not duplicated.")
    }

    nonisolated private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}
