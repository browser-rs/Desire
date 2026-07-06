import SwiftUI

struct MarkdownRendererView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.indices, id: \.self) { index in
                renderBlock(blocks[index])
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
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

    private func inlineContent(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = Font.system(size: 13)

        // Inline code: `code`
        let codePattern = try! NSRegularExpression(pattern: "`([^`]+)`")
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in codePattern.matches(in: text, range: nsRange).reversed() {
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
        let boldPattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
        let nsRange2 = NSRange(text.startIndex..., in: text)
        for match in boldPattern.matches(in: text, range: nsRange2).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let fullRange = Range(match.range(at: 0), in: text)!
            var boldAttr = AttributedString(String(text[range]))
            boldAttr.font = Font.system(size: 13).weight(.bold)
            if let aRange = Range(fullRange, in: attributed) {
                attributed.replaceSubrange(aRange, with: boldAttr)
            }
        }

        // Italic: *text*
        let italicPattern = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")
        let nsRange3 = NSRange(text.startIndex..., in: text)
        for match in italicPattern.matches(in: text, range: nsRange3).reversed() {
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textColor).opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case codeBlock(language: String?, code: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case thematicBreak
    case empty
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
}

#Preview {
    ScrollView {
        MarkdownRendererView(text: """
# Hello World

This is a **bold** and *italic* text with `inline code`.

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
