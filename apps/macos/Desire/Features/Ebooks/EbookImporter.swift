import AppKit
import CryptoKit
import Foundation
import PDFKit

/// 电子书导入（v0.8.34）：SHA-256 去重、EPUB 解包/解析、TXT 解码分章。
/// 文件操作在后台任务里跑；EPUB 解包复用 ArchiveEngine 的 zip-slip 校验。
nonisolated enum EbookImporter {

    enum ImportError: LocalizedError {
        case unsupported(String)
        case emptyFile
        case invalidEPUB
        case drmProtected
        case emptyText
        case converterMissing
        case conversionFailed(String)
        case noImages

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                return String(localized: "Unsupported ebook format: \(ext)")
            case .emptyFile:
                return String(localized: "This file is empty.")
            case .invalidEPUB:
                return String(localized: "This EPUB is missing a readable package or spine.")
            case .drmProtected:
                return String(localized: "This ebook is DRM-protected and cannot be opened.")
            case .emptyText:
                return String(localized: "This text file has no readable content.")
            case .converterMissing:
                return String(localized: "MOBI/AZW3 needs Calibre's ebook-convert. Install Calibre and try again.")
            case .conversionFailed(let message):
                return String(localized: "Ebook conversion failed: \(message)")
            case .noImages:
                return String(localized: "This comic archive has no readable images.")
            }
        }
    }

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Desire/Ebooks", isDirectory: true)
    }

    static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hashString(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 导入（调用方保证在后台任务里跑）。`hash` 由调用方先算好以便去重。
    static func importBook(at url: URL, hash: String) async throws -> Ebook {
        let manager = FileManager.default
        let root = rootDirectory
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let extensionName = url.pathExtension.lowercased()
        if extensionName == "mobi" || extensionName == "azw3" {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            guard fileSize > 0 else { throw ImportError.emptyFile }
            let containerDirectory = hash
            let bookDirectory = root.appendingPathComponent(containerDirectory, isDirectory: true)
            try? manager.removeItem(at: bookDirectory)
            try manager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            let converted = try await convertToEPUB(url: url)
            defer { try? manager.removeItem(at: converted) }
            return try await importEPUB(url: converted, hash: hash, fileSize: fileSize,
                                        bookDirectory: bookDirectory,
                                        containerDirectory: containerDirectory,
                                        displayName: url.lastPathComponent)
        }
        if extensionName == "fb2" {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            guard fileSize > 0 else { throw ImportError.emptyFile }
            let containerDirectory = hash
            let bookDirectory = root.appendingPathComponent(containerDirectory,
                                                            isDirectory: true)
            try? manager.removeItem(at: bookDirectory)
            try manager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            return try importFB2(url: url, hash: hash, fileSize: fileSize,
                                 bookDirectory: bookDirectory,
                                 containerDirectory: containerDirectory)
        }
        guard let format = EbookFormat(fileExtension: extensionName) else {
            throw ImportError.unsupported(extensionName.isEmpty ? "?" : extensionName)
        }
        guard format == .epub || format == .txt || format == .cbz
                || format == .markdown || format == .html || format == .pdf else {
            throw ImportError.unsupported(extensionName)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        guard fileSize > 0 else { throw ImportError.emptyFile }
        let containerDirectory = hash
        let bookDirectory = root.appendingPathComponent(containerDirectory, isDirectory: true)
        try? manager.removeItem(at: bookDirectory)
        try manager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)

        switch format {
        case .epub:
            return try await importEPUB(url: url, hash: hash, fileSize: fileSize,
                                        bookDirectory: bookDirectory,
                                        containerDirectory: containerDirectory)
        case .txt:
            return try importTXT(url: url, hash: hash, fileSize: fileSize,
                                 bookDirectory: bookDirectory,
                                 containerDirectory: containerDirectory)
        case .cbz:
            return try await importCBZ(url: url, hash: hash, fileSize: fileSize,
                                       bookDirectory: bookDirectory,
                                       containerDirectory: containerDirectory)
        case .markdown:
            return try importMarkdown(url: url, hash: hash, fileSize: fileSize,
                                      bookDirectory: bookDirectory,
                                      containerDirectory: containerDirectory)
        case .html:
            return try importHTML(url: url, hash: hash, fileSize: fileSize,
                                  bookDirectory: bookDirectory,
                                  containerDirectory: containerDirectory)
        case .pdf:
            return try importPDF(url: url, hash: hash, fileSize: fileSize,
                                 bookDirectory: bookDirectory,
                                 containerDirectory: containerDirectory)
        }
    }

    // MARK: - EPUB

    private static func importEPUB(url: URL, hash: String, fileSize: Int64,
                                   bookDirectory: URL,
                                   containerDirectory: String,
                                   displayName: String? = nil) async throws -> Ebook {
        let manager = FileManager.default
        _ = try await ArchiveEngine.extract(archive: url, to: bookDirectory)

        let metaDirectory = bookDirectory.appendingPathComponent("META-INF", isDirectory: true)
        let encryption = metaDirectory.appendingPathComponent("encryption.xml")
        if let data = try? Data(contentsOf: encryption), EbookCore.isEncrypted(encryptionXML: data) {
            throw ImportError.drmProtected
        }
        let container = metaDirectory.appendingPathComponent("container.xml")
        guard let containerData = try? Data(contentsOf: container),
              let rootfile = EbookCore.rootfilePath(container: containerData) else {
            throw ImportError.invalidEPUB
        }
        let opfURL = bookDirectory.appendingPathComponent(rootfile)
        guard let opfData = try? Data(contentsOf: opfURL),
              let package = EbookCore.parseOPF(opfData, opfPath: rootfile) else {
            throw ImportError.invalidEPUB
        }
        var coverPath: String?
        if let href = package.metadata.coverHref {
            let file = bookDirectory.appendingPathComponent(href)
            if manager.fileExists(atPath: file.path) { coverPath = href }
        }
        let sourceName = displayName ?? url.lastPathComponent
        let title = package.metadata.title.isEmpty
            ? (sourceName as NSString).deletingPathExtension
            : package.metadata.title
        return Ebook(id: UUID(), title: title.isEmpty ? sourceName : title,
                     author: package.metadata.author,
                     format: .epub, fileName: sourceName,
                     containerDirectory: containerDirectory,
                     coverPath: coverPath, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: max(1, package.chapters.count),
                     hash: hash)
    }

    // MARK: - TXT

    private static func importTXT(url: URL, hash: String, fileSize: Int64,
                                  bookDirectory: URL,
                                  containerDirectory: String) throws -> Ebook {
        let manager = FileManager.default
        let destination = bookDirectory.appendingPathComponent(url.lastPathComponent)
        try manager.copyItem(at: url, to: destination)
        guard let data = try? Data(contentsOf: destination),
              let text = EbookCore.decodeTXT(data) else {
            throw ImportError.emptyText
        }
        let chapters = EbookCore.splitTXT(text)
        guard !chapters.isEmpty else { throw ImportError.emptyText }
        let title = (url.lastPathComponent as NSString).deletingPathExtension
        return Ebook(id: UUID(), title: title.isEmpty ? url.lastPathComponent : title,
                     author: "", format: .txt, fileName: url.lastPathComponent,
                     containerDirectory: containerDirectory,
                     coverPath: nil, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: chapters.count, hash: hash)
    }

    // MARK: - Markdown / HTML

    private struct LocalizedAssets {
        var text: String
        var coverPath: String?
        var count: Int
    }

    private static func importMarkdown(url: URL, hash: String, fileSize: Int64,
                                       bookDirectory: URL,
                                       containerDirectory: String) throws -> Ebook {
        guard let data = try? Data(contentsOf: url),
              let text = EbookCore.decodeTXT(data) else {
            throw ImportError.emptyText
        }
        let localized = localizeAssets(
            in: text,
            pattern: "!\\[[^\\]]*\\]\\(([^)\\s]+)\\)",
            urlGroup: 1,
            sourceDirectory: url.deletingLastPathComponent(),
            bookDirectory: bookDirectory)
        let chapters = EbookCore.splitMarkdown(localized.text)
        guard !chapters.isEmpty else { throw ImportError.emptyText }
        try Data(localized.text.utf8).write(
            to: bookDirectory.appendingPathComponent("source.md"), options: .atomic)
        return Ebook(id: UUID(), title: baseName(url), author: "",
                     format: .markdown, fileName: "source.md",
                     containerDirectory: containerDirectory,
                     coverPath: localized.coverPath, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: chapters.count, hash: hash)
    }

    private static func importHTML(url: URL, hash: String, fileSize: Int64,
                                   bookDirectory: URL,
                                   containerDirectory: String) throws -> Ebook {
        guard let data = try? Data(contentsOf: url),
              let text = EbookCore.decodeTXT(data) else {
            throw ImportError.emptyText
        }
        let sanitized = EbookCore.sanitizeHTML(text)
        let localized = localizeAssets(
            in: sanitized,
            pattern: "(?i)<img\\b[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']",
            urlGroup: 1,
            sourceDirectory: url.deletingLastPathComponent(),
            bookDirectory: bookDirectory)
        let plain = EbookSearchCore.plainText(fromHTML: localized.text)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyText
        }
        try Data(localized.text.utf8).write(
            to: bookDirectory.appendingPathComponent("index.html"), options: .atomic)
        let title = htmlTitle(localized.text) ?? baseName(url)
        return Ebook(id: UUID(), title: title, author: "",
                     format: .html, fileName: "index.html",
                     containerDirectory: containerDirectory,
                     coverPath: localized.coverPath, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: 1, hash: hash)
    }

    /// 把 Markdown/HTML 里引用的相对图片复制进书库 `assets/` 并改写路径。
    private static func localizeAssets(in text: String, pattern: String, urlGroup: Int,
                                       sourceDirectory: URL,
                                       bookDirectory: URL) -> LocalizedAssets {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else {
            return LocalizedAssets(text: text, coverPath: nil, count: 0)
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let assets = bookDirectory.appendingPathComponent("assets", isDirectory: true)
        var replacements: [(NSRange, String)] = []
        var count = 0
        var cover: String?
        for match in matches {
            guard match.numberOfRanges > urlGroup,
                  let range = Range(match.range(at: urlGroup), in: text) else { continue }
            let raw = String(text[range])
            guard let source = safeAssetURL(raw, relativeTo: sourceDirectory) else { continue }
            let name = "asset-\(count).\(sanitizedExtension(source.pathExtension))"
            let destination = assets.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: assets, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            } catch {
                continue
            }
            if cover == nil { cover = "assets/\(name)" }
            replacements.append((match.range(at: urlGroup), "assets/\(name)"))
            count += 1
        }
        guard !replacements.isEmpty else {
            return LocalizedAssets(text: text, coverPath: nil, count: 0)
        }
        var output = text
        for (range, value) in replacements.reversed() {
            guard let swiftRange = Range(range, in: output) else { continue }
            output.replaceSubrange(swiftRange, with: value)
        }
        return LocalizedAssets(text: output, coverPath: cover, count: count)
    }

    private static func safeAssetURL(_ raw: String, relativeTo directory: URL) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value = String(value.dropFirst().dropLast())
        }
        value = value.removingPercentEncoding ?? value
        guard !value.isEmpty,
              !value.hasPrefix("http://"),
              !value.hasPrefix("https://"),
              !value.hasPrefix("data:"),
              !value.hasPrefix("mailto:"),
              !value.hasPrefix("/") else { return nil }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<cut])
        }
        let allowed = ["jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "tiff", "bmp"]
        let ext = (value as NSString).pathExtension.lowercased()
        guard allowed.contains(ext) else { return nil }
        let url = directory.appendingPathComponent(value).standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard url.path.hasPrefix(base + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func sanitizedExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "img" : cleaned
    }

    private static func baseName(_ url: URL) -> String {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? url.lastPathComponent : name
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var title = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        title = title
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return title
    }

    // MARK: - FB2

    /// FB2 转成最小 EPUB 目录后按 EPUB 读（复用阅读/搜索/目录管线）。
    private static func importFB2(url: URL, hash: String, fileSize: Int64,
                                  bookDirectory: URL,
                                  containerDirectory: String) throws -> Ebook {
        guard let data = try? Data(contentsOf: url),
              let parsed = FB2Core.parse(data),
              !parsed.chapters.isEmpty else {
            throw ImportError.emptyText
        }
        let manager = FileManager.default
        let oebps = bookDirectory.appendingPathComponent("OEBPS", isDirectory: true)
        let meta = bookDirectory.appendingPathComponent("META-INF", isDirectory: true)
        let imagesDir = oebps.appendingPathComponent("images", isDirectory: true)
        try manager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try manager.createDirectory(at: meta, withIntermediateDirectories: true)

        var imageItems: [(href: String, media: String)] = []
        for image in parsed.images {
            let safeID = image.id.replacingOccurrences(of: "/", with: "-")
            let name = "fb2-\(safeID).\(FB2Core.fileExtension(for: image.mediaType))"
            try image.data.write(to: imagesDir.appendingPathComponent(name),
                                 options: .atomic)
            imageItems.append((href: "images/\(name)", media: image.mediaType))
        }

        var chapterItems: [String] = []
        var navItems: [String] = []
        for (index, chapter) in parsed.chapters.enumerated() {
            let file = "chapter-\(index).xhtml"
            let document = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><meta charset="utf-8"/><title>\(xmlEscape(chapter.title))</title></head>
            <body><h2>\(xmlEscape(chapter.title))</h2>\(chapter.html)</body></html>
            """
            try Data(document.utf8).write(to: oebps.appendingPathComponent(file),
                                          options: .atomic)
            chapterItems.append(
                "<item id=\"chapter\(index)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>")
            navItems.append(
                "<li><a href=\"\(file)\">\(xmlEscape(chapter.title))</a></li>")
        }

        var manifest = chapterItems
        for (index, image) in imageItems.enumerated() {
            let cover = index == 0 ? " properties=\"cover-image\"" : ""
            manifest.append(
                "<item id=\"img\(index)\" href=\"\(image.href)\" media-type=\"\(image.media)\"\(cover)/>")
        }
        manifest.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        let spine = parsed.chapters.indices
            .map { "<itemref idref=\"chapter\($0)\"/>" }
            .joined(separator: "\n    ")
        var metadata = """
          <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
          <dc:title>\(xmlEscape(parsed.title))</dc:title>
          <dc:language>en</dc:language>
        """
        if !parsed.author.isEmpty {
            metadata += "\n  <dc:creator>\(xmlEscape(parsed.author))</dc:creator>"
        }
        if !imageItems.isEmpty {
            metadata += "\n  <meta name=\"cover\" content=\"img0\"/>"
        }
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadata)
          </metadata>
          <manifest>
            \(manifest.joined(separator: "\n    "))
          </manifest>
          <spine>
            \(spine)
          </spine>
        </package>
        """
        try Data(opf.utf8).write(to: oebps.appendingPathComponent("content.opf"),
                                 options: .atomic)

        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc"><h1>Contents</h1><ol>
        \(navItems.joined(separator: "\n"))
        </ol></nav></body></html>
        """
        try Data(nav.utf8).write(to: oebps.appendingPathComponent("nav.xhtml"),
                                 options: .atomic)

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try Data(container.utf8).write(to: meta.appendingPathComponent("container.xml"),
                                       options: .atomic)

        let coverPath = imageItems.first.map { "OEBPS/\($0.href)" }
        return Ebook(id: UUID(), title: parsed.title, author: parsed.author,
                     format: .epub, fileName: url.lastPathComponent,
                     containerDirectory: containerDirectory,
                     coverPath: coverPath, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: parsed.chapters.count, hash: hash)
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - PDF（v0.8.44）

    /// PDF 入书架：原文件复制进容器（outline/批注随文件保留），首页缩略做封面。
    /// 加密 PDF 拒收（同 DRM 语义）。
    static func importPDF(url: URL, hash: String, fileSize: Int64,
                          bookDirectory: URL,
                          containerDirectory: String) throws -> Ebook {
        let manager = FileManager.default
        let destination = bookDirectory.appendingPathComponent(url.lastPathComponent)
        try manager.copyItem(at: url, to: destination)
        guard let document = PDFDocument(url: destination) else {
            throw ImportError.conversionFailed(String(localized: "This PDF could not be opened."))
        }
        guard !document.isLocked else { throw ImportError.drmProtected }
        let pageCount = max(1, document.pageCount)

        // 封面：首页缩略图 → cover.png（书架卡片沿用 coverPath 语义）。
        var coverPath: String?
        if let first = document.page(at: 0) {
            let aspect = max(0.2, min(5, first.bounds(for: .mediaBox).width
                / max(1, first.bounds(for: .mediaBox).height)))
            let height: CGFloat = 640
            let thumbnail = first.thumbnail(of: CGSize(width: height * aspect,
                                                       height: height),
                                           for: .mediaBox)
            if let tiff = thumbnail.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let coverURL = bookDirectory.appendingPathComponent("cover.png")
                try? png.write(to: coverURL)
                coverPath = "cover.png"
            }
        }

        // 标题：PDF 元数据优先，退化文件名。属性键 Swift 侧无常量名，用 rawValue。
        let fallback = (url.lastPathComponent as NSString).deletingPathExtension
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute(rawValue: "Title")] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Ebook(id: UUID(),
                     title: title.isEmpty ? fallback : title,
                     author: attributes[PDFDocumentAttribute(rawValue: "Author")] as? String ?? "",
                     format: .pdf, fileName: url.lastPathComponent,
                     containerDirectory: containerDirectory,
                     coverPath: coverPath, addedAt: Date(), lastOpenedAt: nil,
                     progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: pageCount, hash: hash)
    }

    /// 书架 PDF 的源文件 URL（阅读器打开用；缺失 = 文件被外部清理）。
    static func pdfFileURL(_ book: Ebook) -> URL {
        rootDirectory
            .appendingPathComponent(book.containerDirectory, isDirectory: true)
            .appendingPathComponent(book.fileName)
    }

    // MARK: - CBZ

    private static func importCBZ(url: URL, hash: String, fileSize: Int64,
                                  bookDirectory: URL,
                                  containerDirectory: String) async throws -> Ebook {
        _ = try await ArchiveEngine.extract(archive: url, to: bookDirectory)
        let images = comicImageURLs(bookDirectory: bookDirectory)
        guard !images.isEmpty else { throw ImportError.noImages }
        let coverPath = images[0].path
            .replacingOccurrences(of: bookDirectory.path + "/", with: "")
        let title = (url.lastPathComponent as NSString).deletingPathExtension
        return Ebook(id: UUID(), title: title.isEmpty ? url.lastPathComponent : title,
                     author: "", format: .cbz, fileName: url.lastPathComponent,
                     containerDirectory: containerDirectory, coverPath: coverPath,
                     addedAt: Date(), lastOpenedAt: nil, progress: 0,
                     lastChapterIndex: 0, chapterProgress: 0,
                     fileSize: fileSize, chapterCount: images.count, hash: hash)
    }

    static func comicImageURLs(bookDirectory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: bookDirectory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        let allowed: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "tiff"]
        var images: [URL] = []
        for case let url as URL in enumerator {
            guard allowed.contains(url.pathExtension.lowercased()) else { continue }
            images.append(url)
        }
        return images.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // MARK: - Calibre（MOBI/AZW3）

    static func findEbookConvert() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ebook-convert",
            "/usr/local/bin/ebook-convert",
            "/opt/local/bin/ebook-convert",
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func convertToEPUB(url: URL) async throws -> URL {
        guard let tool = findEbookConvert() else { throw ImportError.converterMissing }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("desire-ebook-\(UUID().uuidString).epub")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [url.path, destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ImportError.conversionFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw ImportError.conversionFailed(String(message.suffix(300)))
        }
        return destination
    }
}
