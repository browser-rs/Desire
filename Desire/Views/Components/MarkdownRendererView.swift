import AppKit
import SwiftUI

struct MarkdownRendererView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let text: String
    /// 这条消息**正在流式输出**（面板把 `isStreamingTail` 传进来）。
    var isLive: Bool = false

    /// 流式期间块数超过它，就退化成纯文本渲染：块渲染每次刷新要重建上千个子视图
    /// （每节含标题、段落、列表、表格、代码块），实测 40KB/200+ 块的回答在流式时
    /// 偶发 0.5s 主线程卡顿（`pending main thread dispatch stuck for 0.51s`），而
    /// **同一段内容按纯文本渲染零卡顿**（最大 0.145s）。阈值取得宽松——普通长回答
    /// 只有 20~40 块，不受影响；流一结束立刻恢复 Markdown。
    private static let liveRenderBlockLimit = 120

    /// Parsed blocks, memoized so re-renders don't re-parse the markdown.
    /// Reparsed only when `text` actually changes (i.e. on each streaming
    /// token for the tail bubble — but not for the bubbles above it, which
    /// is the win: before this, every token re-parsed *every* bubble).
    @State private var blocks: [MarkdownBlock] = []

    private var prefersPlainText: Bool {
        isLive && blocks.count > Self.liveRenderBlockLimit
    }

    var body: some View {
        Group {
            if prefersPlainText {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks.indices, id: \.self) { index in
                        renderBlock(blocks[index])
                    }
                }
            }
        }
        // **解析必须在主线程之外**：流式输出时这段文本每 ~80ms 变一次，而整段
        // 重解析（含每块的内联正则）随文本长度增长——放主线程会把 UI 卡住
        // （实测 40KB 回答：主线程被阻塞 ~0.5s/次，日志里是 WebKit 的
        // "pending main thread dispatch stuck for 0.51s"，2026-09-21 复现）。
        // `.task(id:)` 会在文本变化时取消上一个任务，所以中间态天然被合并。
        .task(id: text) {
            let snapshot = text
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(snapshot)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(inlineContent(content))
                .font(.system(size: headingSize(level), weight: .semibold))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let lang, let code):
            CodeBlockView(code: code, language: lang)
        case .paragraph(let content):
            Text(inlineContent(content))
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13))
                        Text(inlineContent(items[i]))
                            .font(.system(size: 13))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(inlineContent(items[i]))
                            .font(.system(size: 13))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(header.indices, id: \.self) { col in
                        Text(inlineContent(header[col]))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(rows[row].indices, id: \.self) { col in
                            Text(inlineContent(rows[row][col]))
                                .font(.system(size: 12))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                    }
                    if row < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textColor).opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        case .blockquote(let content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(appAccent.opacity(0.55))
                    .frame(width: 2.5)
                Text(inlineContent(content))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .thematicBreak:
            Divider()
        case .empty:
            Spacer().frame(height: 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    /// 内联渲染结果的缓存：`buildInlineContent` 对每个块跑 5 条正则并重建
    /// AttributedString，而**每次重绘**都会把整条消息的每个块再走一遍（流式时
    /// 约 12 次/秒）。按源文本缓存后，只有新出现的块才付这份成本。
    /// 上限 500 条，超了丢最早的一半（消息滚出屏幕后没人再查）。
    private static var inlineCache: [String: AttributedString] = [:]
    private static var inlineCacheOrder: [String] = []

    private func inlineContent(_ text: String) -> AttributedString {
        if let cached = Self.inlineCache[text] { return cached }
        let attributed = Self.buildInlineContent(text)
        Self.inlineCache[text] = attributed
        Self.inlineCacheOrder.append(text)
        if Self.inlineCacheOrder.count > 500 {
            for key in Self.inlineCacheOrder.prefix(250) {
                Self.inlineCache.removeValue(forKey: key)
            }
            Self.inlineCacheOrder.removeFirst(250)
        }
        return attributed
    }

    private static func buildInlineContent(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = Font.system(size: 13)

        // Markdown links: [label](url) — rendered tappable.
        let nsRangeLinks = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.link.matches(in: text, range: nsRangeLinks).reversed() {
            guard let labelRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: String(text[urlRange])) else { continue }
            let fullRange = Range(match.range(at: 0), in: text)!
            var linkAttr = AttributedString(String(text[labelRange]))
            linkAttr.link = url
            linkAttr.foregroundColor = .accentColor
            linkAttr.underlineStyle = .single
            if let aRange = Range(fullRange, in: attributed) {
                attributed.replaceSubrange(aRange, with: linkAttr)
            }
        }

        // Bare URLs: autolink anything not already inside markdown syntax.
        let nsRangeBare = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.bareURL.matches(in: text, range: nsRangeBare).reversed() {
            guard let range = Range(match.range, in: text),
                  let url = URL(string: String(text[range])) else { continue }
            var linkAttr = AttributedString(String(text[range]))
            linkAttr.link = url
            linkAttr.foregroundColor = .accentColor
            linkAttr.underlineStyle = .single
            if let aRange = Range(range, in: attributed) {
                attributed.replaceSubrange(aRange, with: linkAttr)
            }
        }

        // Inline code: `code`
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.code.matches(in: text, range: nsRange).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let fullRange = Range(match.range(at: 0), in: text)!
            let codeStr = String(text[range])
            var codeAttr = AttributedString(codeStr)
            codeAttr.font = Font.system(size: 12, design: .monospaced)
            codeAttr.backgroundColor = Color(nsColor: .separatorColor).opacity(0.15)
            if let aRange = Range(fullRange, in: attributed) {
                attributed.replaceSubrange(aRange, with: codeAttr)
            }
        }

        // Bold: **text**
        let nsRange2 = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.bold.matches(in: text, range: nsRange2).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let fullRange = Range(match.range(at: 0), in: text)!
            var boldAttr = AttributedString(String(text[range]))
            boldAttr.font = Font.system(size: 13).weight(.bold)
            if let aRange = Range(fullRange, in: attributed) {
                attributed.replaceSubrange(aRange, with: boldAttr)
            }
        }

        // Italic: *text*
        let nsRange3 = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.italic.matches(in: text, range: nsRange3).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let fullRange = Range(match.range(at: 0), in: text)!
            var italicAttr = AttributedString(String(text[range]))
            italicAttr.font = Font.system(size: 13).italic()
            if let aRange = Range(fullRange, in: attributed) {
                attributed.replaceSubrange(aRange, with: italicAttr)
            }
        }

        return attributed
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textColor).opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Copy code")
                .padding(5)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }
}

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case codeBlock(language: String?, code: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    /// Pipe table: header cells + body rows (ragged rows are padded).
    case table(header: [String], rows: [[String]])
    case blockquote(String)
    case thematicBreak
    case empty
}

/// Compiled once and reused — `inlineContent` used to compile these three
/// `NSRegularExpression`s on every call (multiple times per bubble per render).
private enum InlinePatterns {
    static let link = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
    static let bareURL = try! NSRegularExpression(pattern: "(?<![\\(\"'])https?://[^\\s<>\"')\\]]+")
    static let code = try! NSRegularExpression(pattern: "`([^`]+)`")
    static let bold = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    static let italic = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")
}

private enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
                i += 1
                continue
            }

            // Thematic break
            if line.trimmingCharacters(in: .whitespaces).matches(of: /^[-*_]{3,}$/).first != nil {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(line) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Pipe table: a row line followed by a |---|---| separator line.
            if Self.isTableRow(line), i + 1 < lines.count, Self.isTableSeparator(lines[i + 1]) {
                let header = Self.tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, Self.isTableRow(lines[i]) {
                    rows.append(Self.tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Blockquote: consecutive "> " lines collapse into one block.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(">") else { break }
                    quoteLines.append(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                        items.append(String(trimmed.dropFirst(2)))
                        i += 1
                    } else if trimmed.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list
            if line.first?.isNumber == true, line.contains(". ") {
                var items: [String] = []
                while i < lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if let dotRange = trimmed.range(of: ". "), trimmed[..<dotRange.lowerBound].allSatisfy(\.isNumber) {
                        items.append(String(trimmed[dotRange.upperBound...]))
                        i += 1
                    } else if trimmed.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Empty line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.empty)
                i += 1
                continue
            }

            // Paragraph: collect consecutive non-empty lines
            var paraLines: [String] = []
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                paraLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(paraLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 }
            else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let content = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .heading(level: level, content: content)
    }

    // MARK: - Table helpers

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.contains("| ")
    }

    /// `| a | b |` / `|---|:--:|` → cells. The separator variant is
    /// recognized by its dashes/colons before splitting.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        return !body.isEmpty && body.split(separator: "|").allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

#Preview {
    ScrollView {
        MarkdownRendererView(text: """
# Hello World

This is a **bold** and *italic* text with `inline code`, a link to [Example](https://example.com), and a bare URL https://github.com.

## Table

| 方案 | 价格 | 说明 |
|------|------|------|
| 基础版 | ¥0 | 每月 10 次 |
| 专业版 | ¥99 | 无限使用 |
| 旗舰版 | ¥299 | 含优先支持 |

> Blockquoted note with **bold** text.

## Lists

- Item one
- Item two
- Item three

1. First
2. Second
3. Third

## Code

```swift
let x = 42
print(x)
```

---

Done.
""")
        .padding()
    }
    .frame(width: 300)
}
