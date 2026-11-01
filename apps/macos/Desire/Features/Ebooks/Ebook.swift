import Foundation

/// 电子书库条目（v0.8.34）。书库文件在 Application Support/Desire/Ebooks/<hash>/；
/// 书架索引走 DiskStore（`ebooks.library`）。
nonisolated enum EbookFormat: String, Codable, Sendable {
    case epub
    case txt
    case markdown
    case html
    case cbz

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "txt": self = .txt
        case "md", "markdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        case "cbz": self = .cbz
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
        }
    }
}

struct Ebook: Codable, Identifiable, Equatable, Sendable {
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

    var authorOrUnknown: String {
        author.isEmpty ? String(localized: "Unknown author") : author
    }
}

struct EbookBookmark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var chapterIndex: Int
    var chapterProgress: Double
    var pageIndex: Int
    var title: String
    var snippet: String
    var createdAt: Date
}
