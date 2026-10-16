import Foundation

/// 会话归档（v27）：窗口关闭时它的会话会被移进 `session-archives/`
/// （`archived-<原始key>-<归档unix秒>.json`，保留最近 5 个）——本类型只做
/// **元数据读取**（列表/时间/标签数/前几个 URL），供「工作区」面板的
/// 「已归档会话」区块、桥端点与智能体工具展示用。
///
/// 为什么自带一个轻量解码镜像而不是直接解 `SavedSession`：`SavedSession`
/// 定义在 TabManager.swift（AppKit/WebKit 依赖，进不了 tests/run.sh 的
/// harness）。这里的镜像只读 `tabs[].url / isOnNewTabPage` 与
/// `selectedIndex`，与磁盘格式（Codable 键名）对齐；完整解码与恢复仍在
/// 应用侧走 `SavedSession` 本体，单一事实源不变。
nonisolated enum SessionArchive {
    struct Entry: Equatable {
        let fileName: String
        /// 归档时刻：优先取文件名里的 unix 秒，拿不到再用文件 mtime。
        let savedAt: Date
        let tabCount: Int
        /// 前几个可读 URL（面板摘要展示用）。
        let topURLs: [String]
    }

    /// 归档目录里全部条目（新→旧）。目录不存在按空处理。
    static func list(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var entries: [Entry] = []
        for file in files where file.lastPathComponent.hasPrefix("archived-")
            && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let entry = entry(fileName: file.lastPathComponent, data: data, modifiedAt: modified) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.savedAt > $1.savedAt }
    }

    /// 单文件解析；坏文件/空会话返回 nil。
    static func entry(fileName: String, data: Data, modifiedAt: Date) -> Entry? {
        guard let wire = try? JSONDecoder().decode(WireSession.self, from: data),
              !wire.tabs.isEmpty else { return nil }
        let urls = wire.tabs.compactMap { tab -> String? in
            guard !tab.isOnNewTabPage, let url = tab.url, !url.isEmpty else { return nil }
            return url
        }
        return Entry(fileName: fileName,
                     savedAt: timestamp(fromFileName: fileName) ?? modifiedAt,
                     tabCount: wire.tabs.count,
                     topURLs: Array(urls.prefix(3)))
    }

    /// 文件名形如 `archived-<key>-<unix秒>.json`；解析失败返回 nil。
    static func timestamp(fromFileName name: String) -> Date? {
        let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        guard let last = stem.split(separator: "-").last, let seconds = Double(last) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 磁盘格式的只读镜像（与 SavedSession 的 Codable 键名对齐）。
    private struct WireSession: Decodable {
        struct WireTab: Decodable {
            let url: String?
            let isOnNewTabPage: Bool

            enum CodingKeys: String, CodingKey { case url, isOnNewTabPage }
        }
        let tabs: [WireTab]
    }
}
