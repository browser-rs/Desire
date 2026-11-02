import Foundation

/// FB2（FictionBook 2）解析（v0.8.36）：标题/作者/章节 HTML/base64 图片。
/// 解析结果在导入时转成 EPUB 目录，复用现有 EPUB 阅读/搜索管线。
nonisolated struct FB2Chapter: Equatable, Sendable {
    var title: String
    var html: String
}

nonisolated struct FB2Image: Equatable, Sendable {
    var id: String
    var mediaType: String
    var data: Data
}

nonisolated struct FB2Book: Equatable, Sendable {
    var title: String
    var author: String
    var chapters: [FB2Chapter]
    var images: [FB2Image]
}

nonisolated enum FB2Core {

    static func parse(_ data: Data) -> FB2Book? {
        let delegate = FB2Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let chapters = delegate.flattenedChapters()
        guard !chapters.isEmpty else { return nil }
        return FB2Book(title: delegate.bookTitle.isEmpty ? "Untitled" : delegate.bookTitle,
                       author: delegate.author,
                       chapters: chapters,
                       images: delegate.images)
    }

    static func fileExtension(for mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }
}

private nonisolated final class FB2Delegate: NSObject, XMLParserDelegate {

    var bookTitle = ""
    var author = ""
    var images: [FB2Image] = []

    private final class Section {
        var title = ""
        var html = ""
        var children: [Section] = []
        var hasTitle = false
        var hasContent = false
    }

    private var rootSections: [Section] = []
    private var stack: [Section] = []
    private var inTitleInfo = false
    private var inBody = false
    private var inBinary = false
    private var binaryID = ""
    private var binaryType = ""
    private var binaryBuffer = ""
    private var textBuffer = ""
    private var blockBuffer = ""
    private var inTitle = false
    private var titleBuffer = ""
    private var inParagraph = false
    private var inlineTag = ""
    private var authorParts: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        textBuffer = ""
        switch elementName.lowercased() {
        case "title-info":
            inTitleInfo = true
        case "body":
            inBody = true
        case "section" where inBody:
            let section = Section()
            if let parent = stack.last {
                parent.children.append(section)
            } else {
                rootSections.append(section)
            }
            stack.append(section)
        case "title":
            inTitle = true
            titleBuffer = ""
        case "p":
            if inTitle {
                titleBuffer += " "
            } else if inBody {
                inParagraph = true
                blockBuffer = ""
            }
        case "subtitle" where inBody:
            inParagraph = true
            blockBuffer = ""
            inlineTag = "h3"
        case "emphasis" where inParagraph:
            flushText()
            blockBuffer += "<em>"
        case "strong" where inParagraph:
            flushText()
            blockBuffer += "<strong>"
        case "strikethrough" where inParagraph:
            flushText()
            blockBuffer += "<s>"
        case "code" where inParagraph:
            flushText()
            blockBuffer += "<code>"
        case "sup" where inParagraph:
            flushText()
            blockBuffer += "<sup>"
        case "sub" where inParagraph:
            flushText()
            blockBuffer += "<sub>"
        case "empty-line" where inBody:
            stack.last?.html += "<br/>"
        case "v" where inBody:
            inParagraph = true
            blockBuffer = ""
            inlineTag = "v"
        case "image" where inBody:
            let href = attributeDict["l:href"] ?? attributeDict["href"] ?? ""
            if href.hasPrefix("#") {
                let id = String(href.dropFirst())
                let tag = "<img src=\"__FB2IMG__\(id)\"/>"
                if inParagraph {
                    flushText()
                    blockBuffer += tag
                } else if let section = stack.last {
                    section.html += tag
                    section.hasContent = true
                }
            }
        case "binary":
            inBinary = true
            binaryID = attributeDict["id"] ?? ""
            binaryType = attributeDict["content-type"] ?? "image/jpeg"
            binaryBuffer = ""
        case "book-title":
            textBuffer = ""
        case "first-name", "middle-name", "last-name", "nickname":
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBinary { binaryBuffer += string; return }
        if inParagraph || inTitle || inTitleInfo { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "book-title":
            if inTitleInfo { bookTitle = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "first-name", "middle-name", "last-name", "nickname":
            if inTitleInfo {
                let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { authorParts.append(value) }
            }
        case "emphasis" where inParagraph:
            flushText()
            blockBuffer += "</em>"
        case "strong" where inParagraph:
            flushText()
            blockBuffer += "</strong>"
        case "strikethrough" where inParagraph:
            flushText()
            blockBuffer += "</s>"
        case "code" where inParagraph:
            flushText()
            blockBuffer += "</code>"
        case "sup" where inParagraph:
            flushText()
            blockBuffer += "</sup>"
        case "sub" where inParagraph:
            flushText()
            blockBuffer += "</sub>"
        case "p":
            if inTitle {
                titleBuffer += textBuffer
            } else if inParagraph {
                blockBuffer += Self.escape(textBuffer)
                appendBlock("<p>\(blockBuffer)</p>")
                inParagraph = false
            }
        case "subtitle" where inParagraph:
            blockBuffer += Self.escape(textBuffer)
            appendBlock("<h3>\(blockBuffer)</h3>")
            inParagraph = false
        case "v" where inParagraph:
            blockBuffer += Self.escape(textBuffer)
            appendBlock("<p>\(blockBuffer)</p>")
            inParagraph = false
        case "title":
            if let section = stack.last {
                let title = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    section.title = title
                    section.hasTitle = true
                }
            }
            inTitle = false
            titleBuffer = ""
        case "section":
            if !inBody { break }
            _ = stack.popLast()
        case "body":
            inBody = false
        case "title-info":
            inTitleInfo = false
            if author.isEmpty {
                author = authorParts.joined(separator: " ")
            }
        case "binary":
            if let data = Data(base64Encoded: binaryBuffer,
                               options: [.ignoreUnknownCharacters]) {
                images.append(FB2Image(id: binaryID, mediaType: binaryType, data: data))
            }
            inBinary = false
            binaryBuffer = ""
            binaryID = ""
        default:
            break
        }
        textBuffer = ""
    }

    private func flushText() {
        if !textBuffer.isEmpty {
            blockBuffer += Self.escape(textBuffer)
            textBuffer = ""
        }
    }

    private func appendBlock(_ html: String) {
        guard let section = stack.last else { return }
        section.html += html
        section.hasContent = true
    }

    func flattenedChapters() -> [FB2Chapter] {
        var out: [FB2Chapter] = []
        func emit(_ section: Section) {
            if section.hasTitle || section.hasContent {
                var title = section.title
                if title.isEmpty { title = "Chapter \(out.count + 1)" }
                let html = section.html.isEmpty ? "<p></p>" : section.html
                out.append(FB2Chapter(title: title, html: rewriteImages(html)))
            }
            for child in section.children { emit(child) }
        }
        for section in rootSections { emit(section) }
        return out
    }

    private func rewriteImages(_ html: String) -> String {
        var output = html
        for image in images {
            let ext = FB2Core.fileExtension(for: image.mediaType)
            let safeID = image.id.replacingOccurrences(of: "/", with: "-")
            output = output.replacingOccurrences(
                of: "__FB2IMG__\(image.id)",
                with: "images/fb2-\(safeID).\(ext)")
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
