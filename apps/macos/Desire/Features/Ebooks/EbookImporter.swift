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
        guard let format = EbookFormat(fileExtension: extensionName) else {
            throw ImportError.unsupported(extensionName.isEmpty ? "?" : extensionName)
        }
        guard format == .epub || format == .txt else {
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
        default:
            throw ImportError.unsupported(extensionName)
        }
    }

    // MARK: - EPUB

    private static func importEPUB(url: URL, hash: String, fileSize: Int64,
                                   bookDirectory: URL,
                                   containerDirectory: String) async throws -> Ebook {
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
        let title = package.metadata.title.isEmpty
            ? (url.lastPathComponent as NSString).deletingPathExtension
            : package.metadata.title
        return Ebook(id: UUID(), title: title.isEmpty ? url.lastPathComponent : title,
                     author: package.metadata.author,
                     format: .epub, fileName: url.lastPathComponent,
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
}
