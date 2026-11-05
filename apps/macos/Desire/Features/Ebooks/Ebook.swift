import Foundation

/// 电子书库条目（v0.8.34）。书库文件在 Application Support/Desire/Ebooks/<hash>/；
/// 书架索引走 DiskStore（`ebooks.library`）。
nonisolated enum EbookFormat: String, Codable, Sendable {
    case epub
    case txt
    case markdown
    case html
    case cbz
    /// PDF（v0.8.44）：书架一等公民，PDFKit 阅读器（进度按页）。
    case pdf

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "txt": self = .txt
        case "md", "markdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        case "cbz": self = .cbz
        case "pdf": self = .pdf
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .txt: return "TXT"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .cbz: return "CBZ"
        case .pdf: return "PDF"
        }
    }
}

nonisolated struct Ebook: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var format: EbookFormat
    /// 书库目录内的源文件名（TXT/HTML 等）或原始文件名（EPUB）。
    var fileName: String
    /// 相对 Ebooks 根目录的容器目录名（当前为 SHA-256）。
    var containerDirectory: String
    /// 封面相对容器目录的路径。
    var coverPath: String?
    var addedAt: Date
    var lastOpenedAt: Date?
    /// 0...1 全书进度（按章节数 + 章内比例）。
    var progress: Double
    var lastChapterIndex: Int
    var chapterProgress: Double
    var fileSize: Int64
    var chapterCount: Int
    var hash: String
    /// 书架组织（v0.8.35）：收藏与自定义分组。optional 保证旧 library JSON 解码。
    var isFavorite: Bool? = nil
    var collection: String? = nil
    /// 元数据（标题/作者/分组/收藏）的 LWW 戳（v0.8.37）；nil = 旧数据，按 addedAt。
    var syncUpdatedAt: Date? = nil
    /// 最近一次由另一台设备推进进度的时间（v0.8.37，用于书架徽标）。
    var syncedProgressAt: Date? = nil

    var favorite: Bool { isFavorite ?? false }

    var collectionName: String? {
        guard let name = collection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    var authorOrUnknown: String {
        author.isEmpty ? String(localized: "Unknown author") : author
    }
}

nonisolated struct EbookBookmark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var chapterIndex: Int
    var chapterProgress: Double
    var pageIndex: Int
    var title: String
    var snippet: String
    var createdAt: Date
}
