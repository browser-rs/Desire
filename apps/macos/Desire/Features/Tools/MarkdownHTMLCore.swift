import Foundation

/// 极简 Markdown → HTML（标题/列表/粗斜体/行内代码/链接/代码块/分隔线）。
/// 覆盖工具箱"预览/复制 HTML"场景，不追求完整 GFM。
nonisolated enum MarkdownHTMLCore {
    static func html(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var index = 0
        var inCode = false
        var codeBuffer: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + codeBuffer.joined(separator: "\n") + "</code></pre>")
                    codeBuffer = []
                    inCode = false
                } else {
                    inCode = true
                }
                index += 1
                continue
            }
            if inCode {
                codeBuffer.append(line)
                index += 1
                continue
            }
            if line.hasPrefix("### ") { out.append("<h3>" + inline(String(line.dropFirst(4))) + "</h3>") }
            else if line.hasPrefix("## ") { out.append("<h2>" + inline(String(line.dropFirst(3))) + "</h2>") }
            else if line.hasPrefix("# ") { out.append("<h1>" + inline(String(line.dropFirst(2))) + "</h1>") }
            else if line == "---" { out.append("<hr>") }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var items: [String] = []
                while index < lines.count,
                      lines[index].hasPrefix("- ") || lines[index].hasPrefix("* ") {
                    items.append("<li>" + inline(String(lines[index].dropFirst(2))) + "</li>")
                    index += 1
                }
                out.append("<ul>" + items.joined() + "</ul>")
                continue
            }
            else if let digits = firstDigits(line), digits > 0,
                    line.dropFirst(String(digits).count).hasPrefix(". ") {
                var ordered: [String] = []
                while index < lines.count, let value = firstDigits(lines[index]),
                      value >= digits,
                      lines[index].dropFirst(String(value).count).hasPrefix(". ") {
                    ordered.append("<li>" + inline(String(lines[index].dropFirst(String(value).count + 2))) + "</li>")
                    index += 1
                }
                out.append("<ol>" + ordered.joined() + "</ol>")
                continue
            }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
            }
            else {
                out.append("<p>" + inline(line) + "</p>")
            }
            index += 1
        }
        _ = lines
        return out.joined(separator: "\n")
    }

    private static func firstDigits(_ line: String) -> Int? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// 行内：先 HTML 转义，再处理 `code`、**粗体**、*斜体*、[文本](链接)。
    static func inline(_ text: String) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // 行内代码优先（保护其中的星号）
        escaped = escaped.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression)
        escaped = escaped.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression)
        escaped = escaped.replacingOccurrences(
            of: "\\*([^*]+)\\*",
            with: "<em>$1</em>",
            options: .regularExpression)
        escaped = escaped.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)",
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression)
        return escaped
    }
}
