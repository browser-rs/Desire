import Foundation

/// 最近打开的本地文件（v0.8.12 基础件 10）：pdf/媒体/表格/图片/zip/文档
/// 经 openLocalFileInTab 打开时统一记账（UserDefaults 上限 20 条，新→旧）。
/// 新标签页"最近本地文件"区与 Remote 文件面（17）共用。
nonisolated enum RecentLocalFiles {

    struct Entry: Codable, Equatable, Identifiable {
        let url: String
        let filename: String
        let kind: String   // pdf | media | sheet | image | archive | document
        let openedAt: Date
        var id: String { url }
    }

    private static let key = "desire.recentLocalFiles"
    private static let cap = 20

    static func kind(forExtension ext: String) -> String {
        let e = ext.lowercased()
        if e == "pdf" { return "pdf" }
        if ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "aac"].contains(e) { return "media" }
        if ["csv", "tsv", "xlsx"].contains(e) { return "sheet" }
        if ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(e) { return "image" }
        if e == "zip" { return "archive" }
        if ["docx", "doc", "rtf", "rtfd", "odt"].contains(e) { return "document" }
        return "file"
    }

    static func record(url: URL) {
        var list = load()
        let urlString = url.absoluteString
        list.removeAll { $0.url == urlString }
        list.insert(Entry(
            url: urlString,
            filename: url.lastPathComponent,
            kind: kind(forExtension: url.pathExtension),
            openedAt: Date()), at: 0)
        if list.count > cap { list.removeLast(list.count - cap) }
        save(list)
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func remove(urlString: String) {
        var list = load()
        list.removeAll { $0.url == urlString }
        save(list)
    }

    private static func save(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
