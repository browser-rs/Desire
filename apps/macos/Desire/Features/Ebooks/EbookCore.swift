import CoreFoundation
import Foundation

/// 电子书纯逻辑（v0.8.34）：EPUB 容器/OPF/NCX/nav 解析、href 归一、
/// HTML 清洗、TXT 解码与分章。全部 Foundation、进 tests/run.sh。
nonisolated enum EbookCore {

    struct Metadata: Equatable, Sendable {
        var title = ""
        var author = ""
        var language = ""
        var publisher = ""
        var identifier = ""
        var coverHref: String?
    }

    struct ManifestItem: Equatable, Sendable {
        var id: String
        var href: String
        var mediaType: String
        var properties: String
    }

    struct Chapter: Equatable, Sendable, Identifiable {
        var index: Int
        var title: String
        var href: String
        var id: Int { index }
    }

    struct TOCItem: Equatable, Sendable {
        var title: String
        var href: String
        var level: Int
        var chapterIndex: Int?
    }

    struct Package: Equatable, Sendable {
        var metadata: Metadata
        var chapters: [Chapter]
        var toc: [TOCItem]
        var opfPath: String
        var opfDirectory: String
        var navHref: String?
        var ncxHref: String?
    }

    struct TXTChapter: Equatable, Sendable, Identifiable {
        var index: Int
        var title: String
        var text: String
        var id: Int { index }
    }

    // MARK: - 容器 / OPF

    /// `META-INF/container.xml` → rootfile full-path（相对书根）。
    static func rootfilePath(container: Data) -> String? {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: container)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.rootfile
    }

    /// 解析 OPF；`opfPath` 是相对书根的路径（如 OEBPS/content.opf）。
    static func parseOPF(_ data: Data, opfPath: String) -> Package? {
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let delegate = OPFDelegate(opfDirectory: opfDirectory)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let manifest = delegate.manifest
        var chapters: [Chapter] = []
        for idref in delegate.spine {
            guard let item = manifest[idref],
                  let href = resolveHref(item.href, baseDirectory: opfDirectory) else { continue }
            chapters.append(Chapter(index: chapters.count, title: titleFromHref(href),
                                    href: href))
        }
        guard !chapters.isEmpty else { return nil }
        var metadata = delegate.metadata
        metadata.title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.author = metadata.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadata.title.isEmpty {
            metadata.title = titleFromHref(chapters[0].href)
        }
        if let coverID = delegate.coverID, let item = manifest[coverID],
           let href = resolveHref(item.href, baseDirectory: opfDirectory) {
            metadata.coverHref = href
        } else if let guideCover = delegate.guideCover,
                  let href = resolveHref(guideCover, baseDirectory: opfDirectory) {
            metadata.coverHref = href
        } else if let item = manifest.values.first(where: {
            $0.properties.split(separator: " ").contains("cover-image")
        }), let href = resolveHref(item.href, baseDirectory: opfDirectory) {
            metadata.coverHref = href
        }
        let navHref = manifest.values.first(where: {
            $0.properties.split(separator: " ").contains("nav")
        }).flatMap { resolveHref($0.href, baseDirectory: opfDirectory) }
        let ncxHref = manifest.values.first(where: {
            $0.mediaType == "application/x-dtbncx+xml"
        }).flatMap { resolveHref($0.href, baseDirectory: opfDirectory) }
        return Package(metadata: metadata, chapters: chapters, toc: [],
                       opfPath: opfPath, opfDirectory: opfDirectory,
                       navHref: navHref, ncxHref: ncxHref)
    }

    /// NCX → 目录（href 已相对书根）。
    static func parseNCX(_ data: Data, opfDirectory: String) -> [TOCItem] {
        let delegate = NCXDelegate(opfDirectory: opfDirectory)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// EPUB3 nav.xhtml → 目录（href 已相对书根）。
    static func parseNav(_ data: Data, opfDirectory: String) -> [TOCItem] {
        let delegate = NavDelegate(opfDirectory: opfDirectory)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// 把目录挂到章节上（按去掉 fragment 的 href 匹配）。
    static func applyingTOC(_ items: [TOCItem], to chapters: [Chapter]) -> [TOCItem] {
        let normalized = chapters.map { $0.href.components(separatedBy: "#").first ?? $0.href }
        return items.map { item in
            var copy = item
            let href = item.href.components(separatedBy: "#").first ?? item.href
            copy.chapterIndex = normalized.firstIndex(of: href)
            return copy
        }
    }

    // MARK: - 路径

    /// href 相对 OPF 目录 → 相对书根的规范化路径；越界/绝对路径返回 nil。
    static func resolveHref(_ href: String, baseDirectory: String) -> String? {
        var clean = href.removingPercentEncoding ?? href
        clean = clean.components(separatedBy: "#").first ?? clean
        clean = clean.components(separatedBy: "?").first ?? clean
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.hasPrefix("/"), !clean.contains("\\") else {
            return nil
        }
        var parts = baseDirectory.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        for component in clean.split(separator: "/", omittingEmptySubsequences: false) {
            let value = String(component)
            if value.isEmpty || value == "." { continue }
            if value == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(value)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static func titleFromHref(_ href: String) -> String {
        let name = (href as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    // MARK: - 清洗

    /// 去掉脚本/内嵌框架/表单/事件属性/ javascript:，保留正文与本地 CSS/图片。
    static func sanitizeHTML(_ html: String) -> String {
        var output = html
        let patterns: [(String, String)] = [
            ("<script\\b[^>]*>[\\s\\S]*?</script>", ""),
            ("<script\\b[^>]*/>", ""),
            ("<iframe\\b[^>]*>[\\s\\S]*?</iframe>", ""),
            ("<iframe\\b[^>]*/>", ""),
            ("<object\\b[^>]*>[\\s\\S]*?</object>", ""),
            ("<embed\\b[^>]*/?>", ""),
            ("<form\\b[^>]*>[\\s\\S]*?</form>", ""),
            ("<meta\\b[^>]*http-equiv\\s*=\\s*[\"']?refresh[^>]*>", ""),
            ("<base\\b[^>]*>", ""),
            ("\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
            ("(?i)(href|src)\\s*=\\s*([\"'])\\s*javascript:[^\"']*\\2", "$1=\"#\""),
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive])
        }
        return output
    }

    /// EPUB 内容加密（DRM）检测；IDPF 字体混淆（embedding）不算 DRM。
    static func isEncrypted(encryptionXML: Data) -> Bool {
        guard let text = String(data: encryptionXML, encoding: .utf8) else { return false }
        if text.range(of: "http://www.idpf.org/2008/embedding", options: .caseInsensitive) != nil {
            return false
        }
        return text.range(of: "<EncryptedData", options: .caseInsensitive) != nil
    }

    // MARK: - TXT

    /// UTF-8 / UTF-16 / GB18030 / Latin-1 兜底。
    static func decodeTXT(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return text
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 按章节标题（第 N 章 / Chapter N）分章；没有标题就按字符上限切。
    static func splitTXT(_ text: String, maxChars: Int = 20_000) -> [TXTChapter] {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let lines = normalized.components(separatedBy: "\n")
        let headingRegex = try? NSRegularExpression(
            pattern: "^\\s*(第[0-9一二三四五六七八九十百千万两]+[章节回卷部篇]|Chapter\\s+\\d+|CHAPTER\\s+\\d+).*$",
            options: [.caseInsensitive])
        var headingIndices: [Int] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if headingRegex?.firstMatch(in: line, options: [], range: range) != nil {
                headingIndices.append(index)
            }
        }
        if headingIndices.count >= 2 {
            var chapters: [TXTChapter] = []
            for (offset, start) in headingIndices.enumerated() {
                let end = offset + 1 < headingIndices.count
                    ? headingIndices[offset + 1] : lines.count
                let title = lines[start].trimmingCharacters(in: .whitespaces)
                let body = lines[(start + 1)..<end]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                chapters.append(TXTChapter(index: chapters.count,
                                           title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title,
                                           text: body))
            }
            return chapters.filter { !$0.text.isEmpty }
                .enumerated()
                .map { offset, chapter in
                    TXTChapter(index: offset, title: chapter.title, text: chapter.text)
                }
        }
        // 无标题：按字符上限在行边界切。
        var chunks: [TXTChapter] = []
        var buffer: [String] = []
        var count = 0
        for line in lines {
            buffer.append(line)
            count += line.count + 1
            if count >= maxChars {
                let body = buffer.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    chunks.append(TXTChapter(index: chunks.count,
                                             title: "Part \(chunks.count + 1)",
                                             text: body))
                }
                buffer.removeAll(keepingCapacity: true)
                count = 0
            }
        }
        let tail = buffer.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            chunks.append(TXTChapter(index: chunks.count,
                                     title: "Part \(chunks.count + 1)", text: tail))
        }
        return chunks
    }

    /// Markdown → 章节（v0.8.35）：`#`~`####` 标题分章；无标题按字符上限切。
    /// 标题行从正文中剥离，保留为章节名。
    static func splitMarkdown(_ text: String, maxChars: Int = 20_000) -> [TXTChapter] {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let lines = normalized.components(separatedBy: "\n")
        let headingRegex = try? NSRegularExpression(
            pattern: "^\\s{0,3}#{1,4}\\s+(.+?)\\s*#*\\s*$")
        var headings: [(index: Int, title: String)] = []
        for (index, line) in lines.enumerated() {
            guard let regex = headingRegex,
                  let match = regex.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let title = String(line[range]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { headings.append((index, title)) }
        }
        guard !headings.isEmpty else {
            return chunkMarkdown(lines, maxChars: maxChars)
        }
        var chapters: [TXTChapter] = []
        func append(title: String, bodyLines: [String]) {
            let body = bodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            chapters.append(TXTChapter(
                index: chapters.count,
                title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title,
                text: body))
        }
        if headings[0].index > 0 {
            append(title: String(localized: "Introduction"),
                   bodyLines: Array(lines[0..<headings[0].index]))
        }
        for (offset, heading) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1].index : lines.count
            guard heading.index + 1 <= end else { continue }
            append(title: heading.title,
                   bodyLines: Array(lines[(heading.index + 1)..<end]))
        }
        if chapters.isEmpty { return chunkMarkdown(lines, maxChars: maxChars) }
        return chapters.enumerated().map {
            TXTChapter(index: $0.offset, title: $0.element.title, text: $0.element.text)
        }
    }

    private static func chunkMarkdown(_ lines: [String], maxChars: Int) -> [TXTChapter] {
        var chunks: [TXTChapter] = []
        var buffer: [String] = []
        var count = 0
        for line in lines {
            buffer.append(line)
            count += line.count + 1
            if count >= maxChars {
                let body = buffer.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    chunks.append(TXTChapter(index: chunks.count,
                                             title: "Part \(chunks.count + 1)",
                                             text: body))
                }
                buffer.removeAll(keepingCapacity: true)
                count = 0
            }
        }
        let tail = buffer.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            chunks.append(TXTChapter(index: chunks.count,
                                     title: "Part \(chunks.count + 1)", text: tail))
        }
        return chunks
    }

    /// TXT 正文 → 段落 HTML（转义后按空行分段）。
    static func txtHTML(_ text: String) -> String {
        let escaped = escapeHTML(text)
        let paragraphs = escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.isEmpty { return "<p></p>" }
        return paragraphs.map { paragraph in
            "<p>" + paragraph.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }.joined(separator: "\n")
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - XMLParser 委托

private nonisolated final class ContainerDelegate: NSObject, XMLParserDelegate {
    var rootfile: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName.lowercased() == "rootfile" {
            rootfile = attributeDict["full-path"]
        }
    }
}

private nonisolated final class OPFDelegate: NSObject, XMLParserDelegate {
    let opfDirectory: String
    var metadata = EbookCore.Metadata()
    var manifest: [String: EbookCore.ManifestItem] = [:]
    var spine: [String] = []
    var coverID: String?
    var guideCover: String?
    private var currentField: String?
    private var buffer = ""

    init(opfDirectory: String) {
        self.opfDirectory = opfDirectory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        buffer = ""
        if local == "item" {
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { return }
            manifest[id] = EbookCore.ManifestItem(
                id: id, href: href,
                mediaType: attributeDict["media-type"] ?? "",
                properties: attributeDict["properties"] ?? "")
        } else if local == "itemref" {
            if let idref = attributeDict["idref"] { spine.append(idref) }
        } else if local == "meta" {
            if attributeDict["name"]?.lowercased() == "cover" {
                coverID = attributeDict["content"]
            }
        } else if local == "reference" {
            if attributeDict["type"]?.lowercased() == "cover" {
                guideCover = attributeDict["href"]
            }
        } else if ["title", "creator", "language", "publisher", "identifier"].contains(local) {
            currentField = local
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        guard currentField == local else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "title": if metadata.title.isEmpty { metadata.title = value }
        case "creator": if metadata.author.isEmpty { metadata.author = value }
        case "language": if metadata.language.isEmpty { metadata.language = value }
        case "publisher": if metadata.publisher.isEmpty { metadata.publisher = value }
        case "identifier": if metadata.identifier.isEmpty { metadata.identifier = value }
        default: break
        }
        currentField = nil
    }
}

private nonisolated final class NCXDelegate: NSObject, XMLParserDelegate {
    let opfDirectory: String
    var items: [EbookCore.TOCItem] {
        collected.sorted { $0.order < $1.order }.map(\.item)
    }
    private struct Point {
        var title = ""
        var src = ""
        var depth = 1
        var order = 0
    }
    private struct Collected {
        var order: Int
        var item: EbookCore.TOCItem
    }
    private var collected: [Collected] = []
    private var stack: [Point] = []
    private var inText = false
    private var textBuffer = ""
    private var order = 0

    init(opfDirectory: String) {
        self.opfDirectory = opfDirectory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "navpoint" {
            order += 1
            stack.append(Point(depth: stack.count + 1, order: order))
        } else if local == "text" {
            inText = true
            textBuffer = ""
        } else if local == "content", !stack.isEmpty {
            stack[stack.count - 1].src = attributeDict["src"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "text" {
            inText = false
            if !stack.isEmpty {
                stack[stack.count - 1].title =
                    textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if local == "navpoint", let point = stack.popLast() {
            if let href = EbookCore.resolveHref(point.src, baseDirectory: opfDirectory),
               !point.title.isEmpty {
                collected.append(Collected(
                    order: point.order,
                    item: EbookCore.TOCItem(title: point.title, href: href,
                                            level: max(0, point.depth - 1),
                                            chapterIndex: nil)))
            }
        }
    }
}

private nonisolated final class NavDelegate: NSObject, XMLParserDelegate {
    let opfDirectory: String
    var items: [EbookCore.TOCItem] = []
    private var olDepth = 0
    private var inAnchor = false
    private var anchorHref = ""
    private var anchorText = ""

    init(opfDirectory: String) {
        self.opfDirectory = opfDirectory
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "ol" {
            olDepth += 1
        } else if local == "a" {
            inAnchor = true
            anchorHref = attributeDict["href"] ?? ""
            anchorText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { anchorText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "ol" {
            olDepth = max(0, olDepth - 1)
        } else if local == "a" {
            let title = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = EbookCore.resolveHref(anchorHref, baseDirectory: opfDirectory),
               !title.isEmpty {
                items.append(EbookCore.TOCItem(title: title, href: href,
                                               level: max(0, olDepth - 1),
                                               chapterIndex: nil))
            }
            inAnchor = false
            anchorHref = ""
            anchorText = ""
        }
    }
}
