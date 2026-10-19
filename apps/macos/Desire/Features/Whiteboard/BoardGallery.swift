import Foundation

/// 白板模板社区（v0.7.24）：站上 `gallery/index.json` 的机读索引与安全 URL
/// 解析。Foundation-only（进 harness）。索引来自网络——**当不可信输入**：
/// 版本不认识拒绝、file 只认相对路径（禁绝对/禁 `..` 跳出）。
nonisolated enum BoardGallery {
    struct Board: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var description: String
        var file: String
        var blocks: Int?
    }

    struct Index: Codable, Equatable {
        var version: Int
        var boards: [Board]
    }

    static let defaultBaseURL = "https://desire.mankong.icu/gallery/"

    /// 解析索引：JSON 无效 / 版本不认识 / 空列表 → nil（宁可拒绝不猜）。
    static func parseIndex(_ data: Data) -> Index? {
        guard let index = try? JSONDecoder().decode(Index.self, from: data),
              index.version == 1, !index.boards.isEmpty else { return nil }
        return index
    }

    /// file → 绝对 URL：只认相对路径（禁绝对 URL / 协议相对 / `..` 跳出 / 反斜杠）。
    static func resolveFileURL(_ file: String, base: String) -> URL? {
        let trimmed = file.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("http:"), !trimmed.hasPrefix("https:"),
              !trimmed.contains(".."), !trimmed.contains("\\") else { return nil }
        guard let baseURL = URL(string: base),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}
