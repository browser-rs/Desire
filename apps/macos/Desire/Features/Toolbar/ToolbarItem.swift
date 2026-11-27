import Foundation

/// 工具栏可选按钮（v0.8.83）：固定位置的按钮只做显示/隐藏，右侧一排按钮
/// 另可排序。默认顺序/可见性与改造前逐项一致——新增按钮默认隐藏，老布局
/// 打开后不多一个像素。
nonisolated enum ToolbarItem: String, Codable, CaseIterable, Identifiable {
    case home
    case zoom
    case extensions
    case syncStatus
    case agent
    case devTools
    case downloads
    case bookmarks
    case readingList
    case share
    case tabOverview
    case reader

    var id: String { rawValue }

    /// 固定位置（left of / around the address bar）：只能显示/隐藏。
    static let fixedItems: [ToolbarItem] = [.home, .zoom, .extensions, .syncStatus]

    /// 右侧一排（可排序）。默认顺序 = v0.8.82 的既定布局。
    static let defaultOrder: [ToolbarItem] = [
        .agent, .devTools, .downloads,
        .bookmarks, .readingList, .share, .tabOverview, .reader
    ]

    /// v0.8.83 新增的按钮默认关闭：默认布局与旧版完全一致。
    static let defaultHidden: Set<ToolbarItem> = [
        .bookmarks, .readingList, .share, .tabOverview, .reader
    ]

    var isReorderable: Bool { !Self.fixedItems.contains(self) }

    var title: String {
        switch self {
        case .home: "Home"
        case .zoom: "Zoom"
        case .extensions: "Plugins"
        case .syncStatus: "Sync Status"
        case .agent: "Agent"
        case .devTools: "Developer Tools"
        case .downloads: "Downloads"
        case .bookmarks: "Bookmarks"
        case .readingList: "Reading List"
        case .share: "Share"
        case .tabOverview: "Tab Overview"
        case .reader: "Reader"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .zoom: "plus.magnifyingglass"
        case .extensions: "puzzlepiece.extension"
        case .syncStatus: "arrow.triangle.2.circlepath"
        case .agent: "wand.and.stars"
        case .devTools: "ladybug"
        case .downloads: "arrow.down.circle"
        case .bookmarks: "bookmark"
        case .readingList: "text.book.closed"
        case .share: "square.and.arrow.up"
        case .tabOverview: "square.grid.2x2"
        case .reader: "book"
        }
    }
}
