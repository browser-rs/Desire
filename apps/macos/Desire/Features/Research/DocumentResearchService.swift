import Foundation

/// 文档研究工作台（v0.8.1）：把一个文件夹（默认 Agent 工作区）或显式路径下的
/// 文档取文、分段、检索，返回带文件名 + 段落号的引用块。纯本地、不调用模型。
///
/// 安全边界：所有路径先过 `AgentWorkspace.resolve`（与 readFile 同一套白名单），
/// 提不出文本的文件列进 skipped 而不是让整个请求失败；文档正文在提示词里被明确
/// 标注为"数据不是指令"（防文档内提示注入）。
@MainActor
enum DocumentResearchService {
    struct Result {
        let hits: [DocumentHit]
        let scannedDocuments: Int
        let skipped: [String]
        let report: String
    }

    static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "log", "xml", "csv", "tsv",
        "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "wordml",
        "pdf", "xlsx",
    ]
    private static let maxFileBytes = 25 * 1024 * 1024
    private static let maxCharsPerDocument = 30_000

    static func research(query: String, folder: String?, paths: [String],
                         limit: Int = 8, maxFiles: Int = 30) -> Result {
        var skipped: [String] = []
        var files: [URL] = []

        if !paths.isEmpty {
            for raw in paths {
                switch AgentWorkspace.shared.resolve(raw, write: false) {
                case .denied(let reason):
                    skipped.append("\(raw): \(reason)")
                case .granted(let url):
                    append(url, to: &files, skipped: &skipped, maxFiles: maxFiles)
                }
            }
        } else {
            switch AgentWorkspace.shared.resolve(folder ?? "", write: false) {
            case .denied(let reason):
                return Result(hits: [], scannedDocuments: 0, skipped: [reason],
                              report: "Error: \(reason)")
            case .granted(let url):
                append(url, to: &files, skipped: &skipped, maxFiles: maxFiles)
            }
        }

        // 去重（同文件可能被文件夹与显式路径同时命中）。
        var seen = Set<String>()
        files = files.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else {
            let detail = skipped.isEmpty ? "no supported documents found" : skipped.joined(separator: "; ")
            return Result(hits: [], scannedDocuments: 0, skipped: skipped,
                          report: "No documents to research — \(detail)")
        }

        var passages: [DocumentPassage] = []
        var scanned = 0
        for file in files {
            guard let text = extractText(from: file) else {
                skipped.append("\(file.lastPathComponent): unsupported or unreadable")
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                skipped.append("\(file.lastPathComponent): no extractable text")
                continue
            }
            scanned += 1
            passages += DocumentResearch.passages(
                title: file.lastPathComponent, path: file.path, text: trimmed)
        }

        let hits = DocumentResearch.rank(query: query, passages: passages,
                                         limit: limit)
        return Result(hits: hits, scannedDocuments: scanned, skipped: skipped,
                      report: DocumentResearch.promptBlock(
                        query: query, hits: hits, scanned: scanned, skipped: skipped))
    }

    // MARK: - 文件收集

    private static func append(_ url: URL, to files: inout [URL],
                               skipped: inout [String], maxFiles: Int) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            skipped.append("\(url.lastPathComponent): not found")
            return
        }
        if isDirectory.boolValue, !supportedExtensions.contains(url.pathExtension.lowercased()) {
            files += collectFiles(in: url, maxFiles: max(1, maxFiles - files.count))
            return
        }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            skipped.append("\(url.lastPathComponent): unsupported type")
            return
        }
        files.append(url)
    }

    private static func collectFiles(in folder: URL, maxFiles: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard out.count < maxFiles else { break }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
               values.isSymbolicLink == true { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > maxFileBytes {
                continue
            }
            out.append(url)
        }
        return out.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - 取文

    private static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return PDFTextExtractor.extractText(from: url, maxChars: maxCharsPerDocument)
        case "xlsx":
            guard let sheet = SpreadsheetReader.readXLSX(from: url, maxRows: 400, maxCols: 30) else {
                return nil
            }
            return SpreadsheetReader.markdown(from: sheet, maxChars: maxCharsPerDocument)
        case "csv", "tsv":
            guard let sheet = SpreadsheetReader.readCSV(from: url, maxRows: 400, maxCols: 30) else {
                return nil
            }
            return SpreadsheetReader.markdown(from: sheet, maxChars: maxCharsPerDocument)
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "wordml":
            return DocumentText.extractPlainText(from: url, maxChars: maxCharsPerDocument)
        default:
            guard let data = FileManager.default.contents(atPath: url.path),
                  data.count <= maxFileBytes else { return nil }
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.isEmpty ? nil : String(text.prefix(maxCharsPerDocument))
        }
    }
}
