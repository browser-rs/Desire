import Foundation
import WebKit

/// 网页存成书（v0.8.35）：把阅读模式提取的干净正文写成一本文库内的
/// 离线 HTML 书——图片经 URLSession 本地化（带 WK cookie + Referer），
/// 同 URL 去重；正文里的脚本/iframe 已在阅读模式提取时剥离。
@MainActor
enum EbookWebBookImporter {

    struct Result {
        let book: Ebook
        let existed: Bool
        let imageCount: Int
        let failedImages: Int
    }

    enum ImportError: LocalizedError {
        case emptyArticle
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .emptyArticle:
                return String(localized: "This page has no readable article text.")
            case .cannotWrite:
                return String(localized: "Could not write this page into the library.")
            }
        }
    }

    private struct LocalizedImages {
        var html: String
        var count: Int
        var failed: Int
        var cover: String?
    }

    struct Written {
        let book: Ebook
        let imageCount: Int
        let failedImages: Int
    }

    static func importArticle(title: String, html: String,
                              baseURL: URL?) async throws -> Result {
        let cleaned = EbookCore.sanitizeHTML(html)
        let plain = EbookSearchCore.plainText(fromHTML: cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw ImportError.emptyArticle }

        let source = baseURL?.absoluteString ?? ""
        let key = source.isEmpty ? "web\n\(title)\n\(cleaned.prefix(2000))" : "web\n\(source)"
        let hash = EbookImporter.hashString(key)
        if let existing = EbookLibraryStore.shared.books.first(where: { $0.hash == hash }) {
            EbookLibraryStore.shared.touch(existing.id)
            return Result(book: existing, existed: true, imageCount: 0, failedImages: 0)
        }
        let written = try await writeArticle(
            title: title, cleanedHTML: cleaned, baseURL: baseURL,
            root: EbookImporter.rootDirectory, hash: hash)
        EbookLibraryStore.shared.register(written.book)
        return Result(book: written.book, existed: false,
                      imageCount: written.imageCount, failedImages: written.failedImages)
    }

    /// 只写书库目录、不登记书架（供导入流程与自动化探针复用）。
    static func writeArticle(title: String, cleanedHTML: String, baseURL: URL?,
                             root: URL, hash: String) async throws -> Written {
        let cleaned = EbookCore.sanitizeHTML(cleanedHTML)
        let manager = FileManager.default
        let directory = root.appendingPathComponent(hash, isDirectory: true)
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let localized = await localizeImages(in: cleaned, baseURL: baseURL,
                                             directory: directory,
                                             session: session, cookies: cookies)
        let document = wrapDocument(title: title, body: localized.html)
        let file = directory.appendingPathComponent("index.html")
        do {
            try Data(document.utf8).write(to: file, options: .atomic)
        } catch {
            throw ImportError.cannotWrite
        }
        let attributes = try? manager.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (baseURL?.host ?? String(localized: "Web page")) : title
        let book = Ebook(id: UUID(), title: displayTitle, author: "",
                         format: .html, fileName: "index.html",
                         containerDirectory: hash, coverPath: localized.cover,
                         addedAt: Date(), lastOpenedAt: nil,
                         progress: 0, lastChapterIndex: 0, chapterProgress: 0,
                         fileSize: size, chapterCount: 1, hash: hash)
        return Written(book: book, imageCount: localized.count,
                       failedImages: localized.failed)
    }

    // MARK: - 图片本地化

    private static func localizeImages(in html: String, baseURL: URL?,
                                       directory: URL, session: URLSession,
                                       cookies: [HTTPCookie]) async -> LocalizedImages {
        guard let regex = try? NSRegularExpression(
            pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else {
            return LocalizedImages(html: html, count: 0, failed: 0, cover: nil)
        }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let images = directory.appendingPathComponent("images", isDirectory: true)
        var replacements: [(NSRange, String)] = []
        var cache: [String: String?] = [:]
        var count = 0
        var failed = 0
        var cover: String?
        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let source = imageSource(in: tag) else { continue }
            let resolved: URL?
            if source.hasPrefix("http://") || source.hasPrefix("https://") {
                resolved = URL(string: source)
            } else if let baseURL {
                resolved = URL(string: source, relativeTo: baseURL)?.absoluteURL
            } else {
                resolved = nil
            }
            guard let url = resolved, let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            let key = url.absoluteString
            let localPath: String?
            if let cached = cache[key] {
                localPath = cached
            } else {
                var stored: String?
                if count < 40,
                   let data = await download(url, referer: baseURL,
                                             cookies: cookies, session: session) {
                    let name = "img-\(count).\(imageExtension(url: url, data: data))"
                    do {
                        try FileManager.default.createDirectory(
                            at: images, withIntermediateDirectories: true)
                        try data.write(to: images.appendingPathComponent(name),
                                       options: .atomic)
                        stored = "images/\(name)"
                        count += 1
                    } catch {
                        stored = nil
                    }
                }
                cache[key] = stored
                localPath = stored
            }
            if let localPath {
                if cover == nil { cover = localPath }
                replacements.append((match.range,
                                     replaceSource(in: tag, with: localPath)))
            } else {
                failed += 1
                replacements.append((match.range, ""))
            }
        }
        var output = html
        for (range, value) in replacements.reversed() {
            guard let swiftRange = Range(range, in: output) else { continue }
            output.replaceSubrange(swiftRange, with: value)
        }
        return LocalizedImages(html: output, count: count, failed: failed, cover: cover)
    }

    private static func imageSource(in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "src\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func replaceSource(in tag: String, with path: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "src\\s*=\\s*[\"'][^\"']+[\"']", options: [.caseInsensitive]) else {
            return tag
        }
        return regex.stringByReplacingMatches(
            in: tag, range: NSRange(tag.startIndex..., in: tag),
            withTemplate: "src=\"\(path)\"")
    }

    private static func download(_ url: URL, referer: URL?,
                                 cookies: [HTTPCookie], session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let host = url.host?.lowercased() ?? ""
        let header = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return nil }
        return data
    }

    private static func imageExtension(url: URL, data: Data) -> String {
        let ext = url.pathExtension.lowercased()
        let allowed = ["jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "tiff", "bmp"]
        if allowed.contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }

    private static func wrapDocument(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(EbookCore.escapeHTML(title))</title></head>
        <body>\(body)</body></html>
        """
    }
}
