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
