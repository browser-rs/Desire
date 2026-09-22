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
                    // 快照枚举，不用 `blocks.indices` + `blocks[index]`：块数在流式期间
                    // 会**减少**（围栏一开吞掉后面几块、列表合并），而下标当 id 时
                    // SwiftUI 可能在缩容的那次更新里拿旧下标去取新数组 → Index out of range。
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        renderBlock(block)
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
            let work = Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(snapshot, isCancelled: { Task.isCancelled })
            }
            // 文本一变，SwiftUI 取消的是**这个** task；解析在 detached 任务里跑，
            // 取消不会自动传下去，所以要显式带一脚，否则旧解析会一直空转到跑完。
            let parsed = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
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
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13))
                        Text(inlineContent(item))
                            .font(.system(size: 13))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(inlineContent(item))
                            .font(.system(size: 13))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inlineContent(cell))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inlineContent(cell))
                                .font(.system(size: 12))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                    }
                    if rowIndex < rows.count - 1 {
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

    /// 内联样式解析：**先收集片段、再拼接**。
    ///
    /// 绝不在遍历中对同一个 `AttributedString` 反复 `replaceSubrange`：每替换一次长度
    /// 就变，而后续 range 是按**原文本**索引算出来的（`Range(_:in:)` 只按偏移映射），
    /// 于是范围错位，最终在 `AttributedString.Guts.replaceSubrange` 里断言崩溃
    /// （2026-09-23 崩溃报告：EXC_BREAKPOINT ← Collections ← buildInlineContent）。
    /// 拼接模型不产生失效索引。
    private static func buildInlineContent(_ text: String) -> AttributedString {
        struct Span {
            /// 在原文本里占据的范围（决定排序与重叠取舍）。
            let range: Range<String.Index>
            /// 输出的文本：链接给 label、`code`/`**bold**` 给内部文本（标记字符随之消失）。
            let output: String
            let style: Style
            var link: URL?

            enum Style { case link, code, bold, italic }
        }

        func matches(_ regex: NSRegularExpression, group: Int) -> [(full: Range<String.Index>, inner: Range<String.Index>)] {
            let whole = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: whole).compactMap { match in
                guard let full = Range(match.range, in: text),
                      let inner = Range(match.range(at: group), in: text) else { return nil }
                return (full, inner)
            }
        }

        var spans: [Span] = []
        /// 先占先得：与已收下的片段重叠就跳过（链接 > 裸链接 > 行内代码 > 粗体 > 斜体）。
        func take(_ span: Span) {
            guard !spans.contains(where: { $0.range.overlaps(span.range) }) else { return }
            spans.append(span)
        }

        // 链接要同时拿 label（group 1）与 URL（group 2），所以单独走一遍匹配。
        let whole = NSRange(text.startIndex..., in: text)
        for match in InlinePatterns.link.matches(in: text, range: whole) {
            guard let full = Range(match.range, in: text),
                  let label = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: String(text[urlRange])) else { continue }
            take(Span(range: full, output: String(text[label]), style: .link, link: url))
        }
        for match in matches(InlinePatterns.bareURL, group: 0) {
            guard let url = URL(string: String(text[match.inner])) else { continue }
            take(Span(range: match.full, output: String(text[match.inner]), style: .link, link: url))
        }
        for match in matches(InlinePatterns.code, group: 1) {
            take(Span(range: match.full, output: String(text[match.inner]), style: .code))
        }
        for match in matches(InlinePatterns.bold, group: 1) {
            take(Span(range: match.full, output: String(text[match.inner]), style: .bold))
        }
        for match in matches(InlinePatterns.italic, group: 1) {
            take(Span(range: match.full, output: String(text[match.inner]), style: .italic))
        }

        var result = AttributedString()
        var cursor = text.startIndex
        func appendPlain(_ slice: Substring) {
            guard !slice.isEmpty else { return }
            var piece = AttributedString(String(slice))
            piece.font = Font.system(size: 13)
            result += piece
        }
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard span.range.lowerBound >= cursor else { continue }   // 防御：重叠已被拦，这里只兜底
            appendPlain(text[cursor..<span.range.lowerBound])
            var piece = AttributedString(span.output)
            switch span.style {
            case .link:
                piece.font = Font.system(size: 13)
                piece.link = span.link
                piece.foregroundColor = AppAccent.current
                piece.underlineStyle = .single
            case .code:
                piece.font = Font.system(size: 12, design: .monospaced)
                piece.backgroundColor = Color(nsColor: .separatorColor).opacity(0.15)
            case .bold:
                piece.font = Font.system(size: 13).weight(.bold)
            case .italic:
                piece.font = Font.system(size: 13).italic()
            }
            result += piece
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex { appendPlain(text[cursor...]) }
        return result
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
    /// `isCancelled` 让解析能被中断：它在 detached 任务里跑，文本一变旧任务就该
    /// 立刻收手，而不是把整段（可能 40KB）解析完再被丢弃。`nonisolated` 是因为
    /// 调用点在 detached 任务里（模块默认 MainActor 隔离）。
    nonisolated static func parse(_ text: String, isCancelled: () -> Bool = { false }) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            // **每一轮都必须推进 i**：下面的 defer 兜底。任何分支忘了 +1 都会变成
            // 死循环（2026-09-23 实测：`parse("1. ")` 无限循环，跟踪里同一行刷了
            // 几百次——流式写有序列表的中间态正好是 "1. "）。defer 在 continue 时
            // 同样执行，所以这条保证是结构性的，不依赖各分支自己收尾。
            let iterationStart = i
            defer { if i == iterationStart { i += 1 } }
            if isCancelled() { return blocks }

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
            //
            // 入口条件必须和循环里用**同一个**字符串（都取 trim 后的版本）：
            // 曾经入口判的是原始行，循环判的是 trim 后的行，于是 `"1. "` 能进
            // 入口、循环里却匹配不上（尾空格被 trim 掉，". " 不复存在），
            // i 一动不动 → 死循环（详见循环顶部的兜底注释）。
            let orderedLine = line.trimmingCharacters(in: .whitespaces)
            if orderedLine.first?.isNumber == true, orderedLine.contains(". ") {
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
