import Foundation

/// 已下载索引：媒体/来源 URL → 落盘文件。
///
/// 批量重跑同一列表（或重试跨批次）时跳过已下载项，防止同一视频按
/// 多个批次重复占盘。`force` 参数（工具/桥）可绕过强制重下。索引走
/// DiskStore（键 `batch-downloaded-index`），上限 2000 条按时间淘汰。
enum BatchDownloadedIndex {
    struct Entry: Codable {
        var file: String
        var at: Date
    }

    private static let cap = 2000
    private static var cache: [String: Entry]?

    private static var index: [String: Entry] {
        if let cache { return cache }
        cache = DiskStore.load([String: Entry].self, key: "batch-downloaded-index") ?? [:]
        return cache!
    }

    static func file(for url: String) -> String? {
        index[url]?.file
    }

    /// 来源页 + 本页第几部（0 = 主条目）：签名地址每次都变，跨批次只能按来源页认；
    /// 但一页可能有多部正片，必须带序号，否则同页第二、三部会被当成"已下载"
    /// （2026-11-26 实测踩过）。
    static func sourceKey(_ pageURL: String, rank: Int) -> String {
        "src|\(pageURL)|#\(rank)"
    }

    static func file(forSource pageURL: String, rank: Int) -> String? {
        guard !pageURL.isEmpty else { return nil }
        return index[sourceKey(pageURL, rank: rank)]?.file
    }

    /// 历史视图（桥只读）。
    static func snapshot() -> [String: Entry] {
        index
    }

    static func record(urls: [String], file: String) {
        var idx = index
        let now = Date()
        for url in urls where !url.isEmpty {
            idx[url] = Entry(file: file, at: now)
        }
        if idx.count > cap {
            let oldest = idx.sorted { $0.value.at < $1.value.at }.prefix(idx.count - cap)
            for (key, _) in oldest { idx.removeValue(forKey: key) }
        }
        cache = idx
        DiskStore.save(idx, key: "batch-downloaded-index")
    }
}
