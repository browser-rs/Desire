import Combine
import Foundation
import PDFKit

/// 最近本地文件的内容索引（⌘⇧F 第六源，v0.8.15）：把最近 50 个本地文件
/// （pdf/docx/csv/md/txt…）的文本快照缓存在内存，命中出 snippet。
/// 取文在 detached 任务里逐文件跑（textutil/PDFKit 取文本身在主线程，
/// 但循环间让出、一次只占几十毫秒），快照写入走主 actor；10 分钟过期重读。
/// 面板打开即 warmUp——首查可能只有文件名命中，内容命中随后跟上。
@MainActor
final class LocalFileContentIndex: ObservableObject {

    static let shared = LocalFileContentIndex()

    /// url → 文本快照（每文件截 8k 字符；50 文件 ≈ 最多几百 KB 内存）。
    private var snapshots: [String: String] = [:]
    private var warmedAt = Date.distantPast
    private var warmInFlight = false

    private static let supportedExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "odt", "csv", "tsv", "xlsx", "md", "txt",
    ]

    /// 后台预热（面板 onAppear 调）；10 分钟内重复调用是 no-op。
    func warmUp() {
        guard !warmInFlight,
              Date().timeIntervalSince(warmedAt) > 600 else { return }
        warmedAt = Date()
        warmInFlight = true
        let files = Array(RecentLocalFiles.load()
            .prefix(50)
            .filter {
                Self.supportedExtensions.contains(
                    ($0.filename as NSString).pathExtension.lowercased())
            })
        Task.detached(priority: .utility) { [weak self] in
            for entry in files {
                guard !Task.isCancelled else { return }
                let text = await Self.readSnapshot(urlString: entry.url)
                await MainActor.run { [weak self] in
                    if let text, !text.isEmpty {
                        self?.snapshots[entry.url] = text
                    } else {
                        self?.snapshots.removeValue(forKey: entry.url)
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.warmInFlight = false
            }
        }
    }

    /// 命中的文件 → SearchEverywhere 行（文件名或内容命中；内容命中带片段）。
    func matchingItems(query: String) -> [SearchEverywhere.Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [SearchEverywhere.Item] = []
        for entry in RecentLocalFiles.load().prefix(50) {
            let titleHit = entry.filename.lowercased().contains(q.lowercased())
            var snippet: String?
            if let content = snapshots[entry.url],
               let range = content.range(of: q, options: .caseInsensitive) {
                let lower = content.index(range.lowerBound, offsetBy: -50, limitedBy: content.startIndex) ?? content.startIndex
                let upper = content.index(range.upperBound, offsetBy: 90, limitedBy: content.endIndex) ?? content.endIndex
                snippet = (lower > content.startIndex ? "…" : "")
                    + content[lower..<upper].replacingOccurrences(of: "\n", with: " ")
            }
            guard titleHit || snippet != nil else { continue }
            out.append(.init(
                source: .localFile,
                id: entry.url,
                title: entry.filename,
                url: entry.url,
                snippet: snippet))
            if out.count >= 20 { break }
        }
        return out
    }

    /// 单文件取文（各走既有管道，主线程短占用；pdf 走文本层）。
    private static func readSnapshot(urlString: String) async -> String? {
        guard let url = URL(string: urlString), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return await MainActor.run { PDFTextExtractor.extractText(from: url, maxChars: 8_000) }
        case "csv", "tsv", "xlsx":
            return await MainActor.run {
                SpreadsheetReader.readCSV(from: url, maxRows: 200, maxCols: 40)
                    .map { SpreadsheetReader.markdown(from: $0) }
            }
        case "docx", "doc", "rtf", "odt":
            return await MainActor.run { DocumentText.extractPlainText(from: url, maxChars: 8_000) }
        case "md", "txt":
            return await MainActor.run {
                (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(8_000)) }
            }
        default:
            return nil
        }
    }
}
