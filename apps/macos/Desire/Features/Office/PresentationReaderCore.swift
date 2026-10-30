import Foundation

/// PPTX 读取的纯逻辑（v0.8.26 办公增强）：从幻灯片的 DrawingML XML 里取出
/// 标题 / 要点（保留层级）/ 备注，并渲染成 Markdown / HTML。
/// 解包与文件读取在 app 侧（`PresentationReader`）。
nonisolated struct PresentationSlide: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var level: Int
        var text: String
    }

    var index: Int
    var title: String
    var bullets: [Line]
    var notes: [String]
}

nonisolated enum PresentationReaderCore {

    // MARK: - 单页解析

    /// 幻灯片 XML → 标题 + 要点。
    static func slide(fromXML xml: String, index: Int) -> PresentationSlide {
        let paragraphs = parseParagraphs(xml)
        let title = paragraphs.first(where: { $0.isTitle && !$0.text.isEmpty })?.text
            ?? paragraphs.first(where: { !$0.text.isEmpty })?.text
            ?? ""
        var bullets: [PresentationSlide.Line] = []
        for paragraph in paragraphs where !paragraph.text.isEmpty && paragraph.text != title {
            bullets.append(.init(level: paragraph.level, text: paragraph.text))
        }
        return PresentationSlide(index: index, title: title, bullets: bullets, notes: [])
    }

    /// 备注页 XML → 备注段落（过滤页脚/页码占位符与模板提示语）。
    static func notes(fromXML xml: String) -> [String] {
        parseParagraphs(xml).compactMap { paragraph in
            let text = paragraph.text
            guard !text.isEmpty else { return nil }
            if paragraph.placeholderType == "sldNum"
                || paragraph.placeholderType == "ftr"
                || paragraph.placeholderType == "dt" { return nil }
            if text.localizedCaseInsensitiveContains("Click to edit Master") { return nil }
            return text
        }
    }

    // MARK: - 渲染

    /// Markdown 大纲：# 标题 + ## 页标题 + 要点 + 备注引用。
    static func markdown(title: String, slides: [PresentationSlide],
                         includeNotes: Bool) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append("# \(title)"); lines.append("") }
        for slide in slides {
            let heading = slide.title.isEmpty ? "Slide \(slide.index)" : "Slide \(slide.index) — \(slide.title)"
            lines.append("## \(heading)")
            for bullet in slide.bullets {
                let indent = String(repeating: "  ", count: max(0, min(bullet.level, 6)))
                lines.append("\(indent)- \(bullet.text)")
            }
            if includeNotes, !slide.notes.isEmpty {
                lines.append("")
                lines.append("> Notes: " + slide.notes.joined(separator: " / "))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 供查看器/打印用的一页 HTML。
    static func html(title: String, slides: [PresentationSlide], includeNotes: Bool) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = ""
        for slide in slides {
            body += "<section class=\"slide\">"
            body += "<div class=\"num\">\(slide.index)</div>"
            body += "<h2>\(esc(slide.title.isEmpty ? "Slide \(slide.index)" : slide.title))</h2>"
            if !slide.bullets.isEmpty {
                body += "<ul>"
                for bullet in slide.bullets {
                    let pad = min(max(bullet.level, 0), 4)
                    body += "<li style=\"margin-left:\(pad * 18)px\">\(esc(bullet.text))</li>"
                }
                body += "</ul>"
            }
            if includeNotes, !slide.notes.isEmpty {
                body += "<div class=\"notes\"><strong>Notes</strong><br>\(esc(slide.notes.joined(separator: " / ")))</div>"
            }
            body += "</section>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:light dark}
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;margin:24px;max-width:900px}
        h1{font-size:22px;margin:0 0 18px}
        .slide{position:relative;border:1px solid rgba(128,128,128,.25);border-radius:10px;padding:14px 18px 14px 52px;margin-bottom:14px}
        .num{position:absolute;left:14px;top:14px;font:600 11px ui-monospace,monospace;opacity:.5}
        h2{font-size:16px;margin:0 0 8px}
        ul{margin:0;padding-left:18px}
        li{font-size:13px;line-height:1.55;margin:2px 0}
        .notes{margin-top:10px;padding:8px 10px;border-radius:6px;background:rgba(128,128,128,.12);font-size:12px;line-height:1.5}
        </style></head><body><h1>\(esc(title.isEmpty ? "Presentation" : title))</h1>\(body)</body></html>
        """
    }

    // MARK: - XML 段落解析

    struct Paragraph: Equatable {
        var text: String
        var level: Int
        var isTitle: Bool
        var placeholderType: String?
    }

    static func parseParagraphs(_ xml: String) -> [Paragraph] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = ParagraphDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.paragraphs
    }

    /// 只关心 a:p / a:pPr(lvl) / a:t（含多 run 拼接）与 p:ph(type)。
    private final class ParagraphDelegate: NSObject, XMLParserDelegate {
        var paragraphs: [Paragraph] = []
        private var currentText = ""
        private var currentLevel = 0
        private var inText = false
        private var shapePlaceholder: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "p:sp":
                shapePlaceholder = nil
            case "p:ph":
                shapePlaceholder = attributeDict["type"] ?? "body"
            case "a:p":
                currentText = ""
                currentLevel = 0
            case "a:pPr":
                if let lvl = attributeDict["lvl"], let value = Int(lvl) {
                    currentLevel = value
                }
            case "a:t":
                inText = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { currentText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "a:t":
                inText = false
            case "a:p":
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let isTitle = shapePlaceholder == "title" || shapePlaceholder == "ctrTitle"
                paragraphs.append(Paragraph(text: trimmed, level: currentLevel,
                                            isTitle: isTitle,
                                            placeholderType: shapePlaceholder))
                currentText = ""
            case "p:sp":
                shapePlaceholder = nil
            default:
                break
            }
        }
    }
}
