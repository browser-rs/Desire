import Foundation

/// A download entity tracked by `DownloadStore`.
///
/// Not `Codable` directly because it carries a runtime `cancel` closure;
/// `DownloadStore` persists a `HistoryItem` mirror instead.
struct DownloadItem: Identifiable {
    let id: UUID
    var filename: String
    var fileURL: URL?
    var totalBytes: Int64
    var downloadedBytes: Int64
    var state: State
    var error: String?
    var cancel: (() -> Void)?
    var sourceURL: URL?
    var priority: Priority = .normal
    var isPaused: Bool = false
    var startTime: Date = Date()
    var lastUpdateTime: Date = Date()
    var speed: Int64 = 0 // bytes per second
    /// Download originated in an incognito tab — never persisted to the
    /// shared download history (in-memory only, like resumeData).
    var isPrivate: Bool = false

    /// Partial-transfer data for pause/retry. In-memory only — resume data
    /// is meaningless after a relaunch, so `HistoryItem` never persists it.
    var resumeData: Data? = nil
    /// WebKit reported this transfer cannot produce usable resume data
    /// (e.g. the server ignores Range requests) — resume restarts from the
    /// source URL instead of checkpointing. In-memory only.
    var resumeUnavailable: Bool = false
    /// Pauses the underlying transfer: `suspend()` for URLSession tasks,
    /// `cancel(byProducingResumeData:)` for webview downloads (whose pause
    /// is a resume-data checkpoint — WKDownload cannot be suspended).
    var pauseAction: (() -> Void)? = nil
    /// Resumes the underlying transfer; receives `resumeData` when set.
    var resumeAction: ((Data?) -> Void)? = nil

    enum State: String, Codable { case inProgress, completed, failed, paused }
    enum Priority: Int, Codable { case low = 0, normal = 1, high = 2 }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var isIndeterminate: Bool { totalBytes <= 0 && state == .inProgress }

    var estimatedTimeRemaining: TimeInterval? {
        guard totalBytes > 0, downloadedBytes > 0, speed > 0 else { return nil }
        let remaining = totalBytes - downloadedBytes
        return TimeInterval(remaining) / TimeInterval(speed)
    }

    var fileType: FileType {
        guard !filename.isEmpty else { return .other }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp": return .image
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm": return .video
        case "mp3", "aac", "wav", "flac", "m4a", "ogg": return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf": return .document
        case "zip", "rar", "tar", "gz", "7z", "dmg", "iso": return .archive
        case "app", "exe", "sh", "bash": return .application
        default: return .other
        }
    }

    enum FileType: String, CaseIterable {
        case image, video, audio, document, archive, application, other
        var icon: String {
            switch self {
            case .image: return "photo"
            case .video: return "video"
            case .audio: return "music.note"
            case .document: return "doc.text"
            case .archive: return "archivebox"
            case .application: return "app"
            case .other: return "doc"
            }
        }
    }
}
