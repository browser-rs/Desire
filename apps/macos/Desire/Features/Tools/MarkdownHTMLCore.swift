import Foundation

/// 极简 Markdown → HTML（标题/列表/引用/图片/粗斜体/行内代码/链接/代码块/分隔线）。
/// 覆盖工具箱"预览/复制 HTML"与电子书 Markdown 阅读，不追求完整 GFM。
nonisolated enum MarkdownHTMLCore {
    static func html(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var index = 0
        var inCode = false
        var codeBuffer: [String] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + escape(codeBuffer.joined(separator: "\n")) + "</code></pre>")
                    codeBuffer = []
                    inCode = false
                } else {
                    inCode = true
                }
                index += 1
                continue
            }
            if inCode {
                codeBuffer.append(lines[index])
                index += 1
                continue
            }
            if line.hasPrefix("#### ") { out.append("<h4>" + inline(String(line.dropFirst(5))) + "</h4>") }
            else if line.hasPrefix("### ") { out.append("<h3>" + inline(String(line.dropFirst(4))) + "</h3>") }
            else if line.hasPrefix("## ") { out.append("<h2>" + inline(String(line.dropFirst(3))) + "</h2>") }
            else if line.hasPrefix("# ") { out.append("<h1>" + inline(String(line.dropFirst(2))) + "</h1>") }
            else if line == "---" || line == "***" || line == "___" { out.append("<hr>") }
            else if line.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(inline(content))
                    index += 1
                }
                out.append("<blockquote><p>" + quoted.joined(separator: "<br>") + "</p></blockquote>")
                continue
            }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") || candidate.hasPrefix("* ")
                            || candidate.hasPrefix("+ ") else { break }
                    items.append("<li>" + inline(String(candidate.dropFirst(2))) + "</li>")
                    index += 1
                }
                out.append("<ul>" + items.joined() + "</ul>")
                continue
            }
            else if let digits = firstDigits(line), digits > 0,
                    line.dropFirst(String(digits).count).hasPrefix(". ") {
                var ordered: [String] = []
                while index < lines.count,
                      let value = firstDigits(lines[index].trimmingCharacters(in: .whitespaces)),
                      value >= digits,
                      lines[index].trimmingCharacters(in: .whitespaces)
                        .dropFirst(String(value).count).hasPrefix(". ") {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    ordered.append("<li>" + inline(String(trimmed.dropFirst(String(value).count + 2))) + "</li>")
                    index += 1
                }
                out.append("<ol>" + ordered.joined() + "</ol>")
                continue
            }
            else if line.isEmpty {
                out.append("")
            }
            else {
                out.append("<p>" + inline(line) + "</p>")
            }
            index += 1
        }
        return out.joined(separator: "\n")
    }

    private static func firstDigits(_ line: String) -> Int? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 行内：先 HTML 转义，再处理图片、`code`、**粗体**、*斜体*、[文本](链接)。
    static func inline(_ text: String) -> String {
        var escaped = escape(text)
        // 行内代码优先（保护其中的星号）
        escaped = escaped.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression)
        // 图片先于链接（否则 ![alt](src) 会被链接规则吃掉）
        escaped = escaped.replacingOccurrences(
            of: "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)",
            with: "<img src=\"$2\" alt=\"$1\">",
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
