import Foundation

/// 从其他浏览器导入的数据模型（v0.8.0）。Foundation-only，解析与合并逻辑
/// 进 harness；真正的文件/进程访问在 `BrowserImportService`。

enum BrowserImportSource: String, CaseIterable, Codable {
    case chrome
    case edge
    case brave
    case arc
    case safari

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .safari: "Safari"
        }
    }

    var isChromium: Bool { self != .safari }
}

/// 一个可导入的浏览器档案（Chromium 的 Default/Profile 1、Safari 单档案）。
struct BrowserImportProfile: Identifiable, Equatable {
    var id: String { "\(source.rawValue)|\(profilePath)" }
    let source: BrowserImportSource
    /// 用户可见名称（Chromium 的 Local State 名字，失败回退目录名）。
    let name: String
    let profilePath: String
    let bookmarksPath: String?
    let historyPath: String?
    let preferencesPath: String?

    var hasBookmarks: Bool { bookmarksPath != nil }
    var hasHistory: Bool { historyPath != nil }
}

/// 历史导入的统一行（时间已换算成 `Date`）。
struct ImportedHistoryEntry: Equatable {
    let url: String
    let title: String
    let timestamp: Date
    let visitCount: Int
}

/// 可导入的设置（只做有明确对应关系的项）。
struct BrowserImportSettings: Equatable {
    var homePage: String?
    var startupURLs: [String] = []

    var isEmpty: Bool { homePage == nil && startupURLs.isEmpty }
}

/// 预览：解析后的完整数据（不落盘；UI/桥用它显示计数）。
struct BrowserImportPreview {
    var bookmarks: [Bookmark] = []
    var history: [ImportedHistoryEntry] = []
    var settings = BrowserImportSettings()
    var warnings: [String] = []

    var bookmarkCount: Int {
        func leaves(_ nodes: [Bookmark]) -> Int {
            nodes.reduce(0) { $0 + ($1.isLeaf ? 1 : leaves($1.children)) }
        }
        return leaves(bookmarks)
    }
    var historyCount: Int { history.count }
}

/// 导入结果（UI 报告/桥回包）。
struct BrowserImportReport {
    var bookmarksImported = 0
    var bookmarksSkipped = 0
    var historyImported = 0
    var historySkipped = 0
    var settingsApplied: [String] = []
    var warnings: [String] = []
}

enum BrowserImportError: LocalizedError {
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "Could not read browser data: \(detail)"
        case .malformed(let detail): "Unrecognized browser data: \(detail)"
        }
    }
}

