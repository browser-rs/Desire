import CryptoKit
import Foundation

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
        guard let format = EbookFormat(fileExtension: extensionName) else {
            throw ImportError.unsupported(extensionName.isEmpty ? "?" : extensionName)
        }
        guard format == .epub || format == .txt || format == .cbz else {
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
        default:
            throw ImportError.unsupported(extensionName)
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
