import Foundation

/// 定时下载（v0.8.0）：到点由 `DownloadScheduler` 交给 `DownloadStore`。
nonisolated struct ScheduledDownload: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var filename: String
    var startAt: Date
    var createdAt: Date

    static func suggestedFilename(for url: URL) -> String {
        let last = url.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "/" { return "download" }
        return last
    }
}
