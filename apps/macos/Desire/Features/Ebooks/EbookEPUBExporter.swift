import Foundation

/// 网页书/HTML 书 → EPUB 3（v0.8.36）。mimetype 必须首个且不压缩，
/// 所以先 `zip -0X` 写 mimetype，再 `zip -rX` 写其余。
nonisolated enum EbookEPUBExporter {

    enum ExportError: LocalizedError {
        case unsupported
        case missingContent
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return String(localized: "Only HTML/web books can be exported to EPUB right now.")
            case .missingContent:
                return String(localized: "This book has no readable HTML content.")
            case .zipFailed(let message):
                return String(localized: "EPUB packaging failed: \(message)")
            }
        }
    }

    static func export(book: Ebook, root: URL, to destination: URL) async throws {
        guard book.format == .html else { throw ExportError.unsupported }
        let source = root.appendingPathComponent(book.containerDirectory,
                                                 isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let index = source.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: index),
              let html = EbookCore.decodeTXT(data) else {
            throw ExportError.missingContent
        }
        let body = extractBody(html)
        guard !EbookSearchCore.plainText(fromHTML: body)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportError.missingContent
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesireEPUB-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let oebps = staging.appendingPathComponent("OEBPS", isDirectory: true)
        let meta = staging.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)

        try Data("application/epub+zip".utf8)
            .write(to: staging.appendingPathComponent("mimetype"), options: .atomic)
        try Data(containerXML.utf8)
            .write(to: meta.appendingPathComponent("container.xml"), options: .atomic)

        let title = book.title.isEmpty ? "Untitled" : book.title
        var manifest: [String] = []
        var images: [(href: String, mediaType: String)] = []

        // 复制章节 HTML 里引用的本地图片（images/ 与 assets/ 原样保留相对路径）。
        for folder in ["images", "assets"] {
            let directory = source.appendingPathComponent(folder, isDirectory: true)
            for file in regularFiles(in: directory) {
                let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
                let relative = resolved.path
                    .replacingOccurrences(of: source.path + "/", with: "")
                let destinationFile = oebps.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: destinationFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: file, to: destinationFile)
                images.append((relative, mediaType(for: file.pathExtension)))
            }
        }
        for (index, image) in images.enumerated() {
            manifest.append("<item id=\"img\(index)\" href=\"\(escape(image.href))\" media-type=\"\(image.mediaType)\"/>")
        }

        var coverItem = ""
        if let coverPath = book.coverPath {
            let coverSource = source.appendingPathComponent(coverPath)
            if let data = try? Data(contentsOf: coverSource),
               let ext = coverPath.split(separator: ".").last.map(String.init) {
                let name = "cover.\(ext)"
                try Data(data).write(to: oebps.appendingPathComponent(name), options: .atomic)
                coverItem = "<item id=\"cover-image\" href=\"\(name)\" media-type=\"\(mediaType(for: ext))\" properties=\"cover-image\"/>"
            }
        }

        let chapter = xhtml(title: title, body: body)
        try Data(chapter.utf8)
            .write(to: oebps.appendingPathComponent("chapter.xhtml"), options: .atomic)
        try Data(navXHTML(title: title).utf8)
            .write(to: oebps.appendingPathComponent("nav.xhtml"), options: .atomic)
        let opf = opfXML(book: book, title: title, manifest: manifest, coverItem: coverItem)
        try Data(opf.utf8)
            .write(to: oebps.appendingPathComponent("content.opf"), options: .atomic)

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try await runZip(staging: staging, destination: destination)
    }

    static func filename(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned: Set<Character> = ["/", "\\", ":", "?", "%", "*", "|", "\"", "<", ">", "\n"]
        var name = String(trimmed.map { banned.contains($0) ? "-" : $0 })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -. "))
        if name.count > 80 { name = String(name.prefix(80)) }
        return (name.isEmpty ? "book" : name) + ".epub"
    }

    // MARK: - 打包

    private static func runZip(staging: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            func run(_ arguments: [String]) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.arguments = arguments
                process.currentDirectoryURL = staging
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    throw ExportError.zipFailed(
                        String(data: data, encoding: .utf8) ?? "zip exit \(process.terminationStatus)")
                }
            }
            try run(["-0X", "-q", destination.path, "mimetype"])
            try run(["-rX", "-q", destination.path, "META-INF", "OEBPS"])
        }.value
    }

    // MARK: - XML

    private static var containerXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private static func opfXML(book: Ebook, title: String,
                               manifest: [String], coverItem: String) -> String {
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = """
          <dc:identifier id="bookid">urn:uuid:\(book.id.uuidString)</dc:identifier>
          <dc:title>\(escape(title))</dc:title>
          <dc:language>en</dc:language>
        """
        if !author.isEmpty {
            metadata += "\n  <dc:creator>\(escape(author))</dc:creator>"
        }
        if !coverItem.isEmpty {
            metadata += "\n  <meta name=\"cover\" content=\"cover-image\"/>"
        }
        let manifestItems = (["<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
                              "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>"]
                             + manifest + (coverItem.isEmpty ? [] : [coverItem]))
            .joined(separator: "\n    ")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadata)
          </metadata>
          <manifest>
            \(manifestItems)
          </manifest>
          <spine>
            <itemref idref="chapter"/>
          </spine>
        </package>
        """
    }

    private static func navXHTML(title: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc"><h1>Contents</h1><ol>
        <li><a href="chapter.xhtml">\(escape(title))</a></li>
        </ol></nav></body></html>
        """
    }

    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><meta charset="utf-8"/><title>\(escape(title))</title></head>
        <body>\(body)</body></html>
        """
    }

    private static func extractBody(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<body\\b[^>]*>([\\s\\S]*?)</body>", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html,
                                           range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return html
        }
        return String(html[range])
    }

    private static func regularFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true {
                files.append(file)
            }
        }
        return files
    }

    private static func mediaType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
