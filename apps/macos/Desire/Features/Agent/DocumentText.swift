import Foundation

/// Word / RTF 等富文本文档取文（端上）：走系统自带 `textutil`
/// （`/usr/bin/textutil -convert txt -stdout`），不引第三方解析器。
/// 覆盖 .docx（Word 2007+）、.doc（旧版二进制）、.rtf、.rtfd、.odt、.html/.htm。
///
/// 分工口径：PDF → `readPdf`；扫描件/截图 → `ocrImage`；表格 → `readSpreadsheet`；
/// 纯文本 → `readFile`。本工具只负责"富文本容器 → 纯文本"。
enum DocumentText {
    static let supportedExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "wordml",
    ]

    /// 富文本 → 纯文本（最多 maxChars）；转换失败/空文档返回 nil。
    static func extractPlainText(from url: URL, maxChars: Int = 60_000) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", "-encoding", "UTF-8", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = collapseBlankLines(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxChars ? String(text.prefix(maxChars)) + "…[truncated]" : text
    }

    /// 正向导出（v0.8.14 基础件 1）：txt/md/html → docx/rtf/html。
    /// textutil 双向可用——此前只用了读取半边。原子写；失败返回 nil。
    static func exportDocument(content: String, format: String, to url: URL) -> Bool {
        let fmt: String
        switch format.lowercased() {
        case "docx": fmt = "docx"
        case "doc": fmt = "doc"
        case "rtf": fmt = "rtf"
        case "html": fmt = "html"
        default: return false
        }
        // 中间产物：md 内容先包成极简 HTML（textutil 对 html 的标题/列表保真
        // 优于纯文本换行），纯文本直接喂。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-export-\(UUID().uuidString).html")
        var html: String
        if content.contains("<h") || content.contains("<p>") || content.contains("<ul") {
            html = content   // 已是 html
        } else {
            let escaped = content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
            // 行级转换：# 标题 → h1-h3；- 条目 → li；其余 → p（简单可靠）
            var body = ""
            for line in escaped.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if l.hasPrefix("### ") { body += "<h3>\(l.dropFirst(4))</h3>" }
                else if l.hasPrefix("## ") { body += "<h2>\(l.dropFirst(3))</h2>" }
                else if l.hasPrefix("# ") { body += "<h1>\(l.dropFirst(2))</h1>" }
                else if l.hasPrefix("- ") { body += "<ul><li>\(l.dropFirst(2))</li></ul>" }
                else if l.trimmingCharacters(in: .whitespaces).isEmpty { body += "<br>" }
                else { body += "<p>\(l)</p>" }
            }
            html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system;}</style></head><body>\(body)</body></html>"
        }
        try? html.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", fmt, "-output", url.path, tmp.path]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return true
    }

    /// textutil 会把空段落摊平成连续空行——压到最多一个（省 token、保段落结构）。
    nonisolated static func collapseBlankLines(_ text: String) -> String {
        var out: [String] = []
        var lastBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let blank = line.allSatisfy { $0 == "\r" || $0 == " " || $0 == "\t" }
            if blank, lastBlank { continue }
            // 空白行统一成空串（不留行内空格）；连续空行只留第一条。
            out.append(blank ? "" : String(line))
            lastBlank = blank
        }
        return out.joined(separator: "\n")
    }
}
