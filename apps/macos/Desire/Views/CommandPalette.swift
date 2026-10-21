import AppKit
import SwiftUI

/// ⌘K 命令面板（0.1.16 起；v0.7.21 升级为**全局混合检索**）：五源聚合——
/// 命令 / 打开中的标签 / 书签 / 历史 / Agent 会话。检索与分组在纯逻辑
/// `PaletteSearch`（进单测），四源快照由 `PaletteSnapshot` 单点构建（与桥
/// `/palette` 同源）；面板自己做渲染、键盘与最近使用。
///
/// 键盘：↑/↓ 选择（只踩行不踩组头）、回车执行、⌘回车对可打开的行走新标签、
/// esc 关闭。空查询 = 初始态：命令按最近使用、标签按窗口顺序。
struct CommandPalette: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color

    /// 命令之外的四个数据源（命令行目录在本文件内）。
    struct DataSources {
        var tabs: [PaletteSearch.Row] = []
        var bookmarks: [PaletteSearch.Row] = []
        var history: [PaletteSearch.Row] = []
        var conversations: [PaletteSearch.Row] = []
    }

    struct CommandEntry {
        let row: PaletteSearch.Row
        let command: BrowserCommand
        let icon: String
    }

    /// 打开时快照一次（面板短命，不做实时观察——store 变化由 ContentView
    /// 的重绘路径兜底，构建成本不必每帧付）。
    let makeSources: () -> DataSources
    /// 命令行的执行（走既有 CommandBus）。
    let onRun: (BrowserCommand) -> Void
    /// 非命令行：回车（newTab=false）/ ⌘回车（newTab=true）。
    let onActivate: (PaletteSearch.Row, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sources = DataSources()
    @State private var query = ""
    @State private var selectedIndex = 0
    /// ↑/↓/enter 以 NSEvents 到达（TextField 在某些焦点态会吞掉方向键），
    /// 面板自持一个作用域键盘监视器。
    @State private var keyMonitor: Any?

    // MARK: - 命令目录（BrowserCommand 枚举即目录，不另起注册表）

    static let catalog: [CommandEntry] = [
        cmd("cmd.newTab", "New Tab", "File", "plus.square.on.square", .newTab),
        cmd("cmd.newIncognitoTab", "New Incognito Tab", "File", "mask", .newIncognitoTab),
        cmd("cmd.newWindow", "New Window", "File", "macwindow.on.rectangle", .newWindow),
        cmd("cmd.closeTab", "Close Tab", "File", "xmark.square", .closeTab),
        cmd("cmd.reopenClosedTab", "Reopen Closed Tab", "File", "arrow.uturn.backward.square", .reopenClosedTab),
        cmd("cmd.savePage", "Save Page", "File", "arrow.down.doc", .savePage),
        cmd("cmd.printPage", "Print…", "Tools", "printer", .printPage),
        cmd("cmd.reload", "Reload Page", "View", "arrow.clockwise", .reload),
        cmd("cmd.forceReload", "Force Reload Page", "View", "arrow.clockwise.circle.fill", .forceReload),
        cmd("cmd.zoomIn", "Zoom In", "View", "plus.magnifyingglass", .zoomIn),
        cmd("cmd.zoomOut", "Zoom Out", "View", "minus.magnifyingglass", .zoomOut),
        cmd("cmd.actualSize", "Actual Size", "View", "1.magnifyingglass", .actualSize),
        cmd("cmd.toggleReader", "Reader View", "View", "doc.richtext", .toggleReader),
        cmd("cmd.toggleResponsiveMode", "Responsive Design Mode", "View", "iphone.radiowaves.left.and.right", .toggleResponsiveMode),
        cmd("cmd.inspectElement", "Inspect Element", "Develop", "scope", .inspectElement),
        cmd("cmd.toggleFind", "Find in Page…", "Edit", "magnifyingglass", .toggleFind),
        cmd("cmd.showHistory", "Show History", "History", "clock.arrow.circlepath", .showHistory),
        cmd("cmd.showWorkflows", "Web Workflows…", "Tools", "rectangle.stack.badge.play", .showWorkflows),
        cmd("cmd.clearHistory", "Clear History…", "History", "trash", .clearHistory),
        cmd("cmd.showBookmarks", "Bookmarks Panel", "Bookmarks", "book", .showBookmarks),
        cmd("cmd.bookmarkPage", "Add Bookmark", "Bookmarks", "bookmark", .bookmarkPage),
        cmd("cmd.showDownloads", "Show Downloads", "View", "arrow.down.circle", .showDownloads),
        cmd("cmd.showSettings", "Settings", "App", "gearshape", .showSettings),
        cmd("cmd.showPlugins", "Plugins", "Tools", "puzzlepiece", .showPlugins),
        cmd("cmd.showElementBlock", "Element Blocker", "Tools", "eye.slash", .showElementBlock),
        cmd("cmd.screenshot", "Screenshot Region…", "Tools", "camera.viewfinder", .screenshot),
        cmd("cmd.exportBackup", "Export Backup Now", "File", "externaldrive", .exportBackup),
        cmd("cmd.exportDiagnostics", "Export Diagnostics…", "Tools", "stethoscope", .exportDiagnostics),
        cmd("cmd.toggleSidebar", "Toggle Sidebar", "Tabs", "sidebar.left", .toggleSidebar),
        cmd("cmd.tabSearch", "Search Tabs", "Tabs", "rectangle.stack", .tabSearch),
        cmd("cmd.toggleFullScreen", "Toggle Full Screen", "View", "arrow.up.left.and.arrow.down.right", .toggleFullScreen),
        cmd("cmd.restoreArchivedSession", "Restore Archived Session…", "Tools", "clock.badge.checkmark", .restoreArchivedSession),
    ]

    private static func cmd(_ id: String, _ title: String, _ category: String,
                            _ icon: String, _ command: BrowserCommand) -> CommandEntry {
        CommandEntry(row: .init(source: .command, id: id, title: title, subtitle: category),
                     command: command, icon: icon)
    }

    // MARK: - 最近使用（精确顺序，持久化在 UserDefaults）

    private static let recentsKey = "commandPalette.recentCommandIDs"
    private static let recentsCap = 12

    static func recentCommandIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    static func recordUse(_ id: String) {
        var list = recentCommandIDs()
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(recentsCap)), forKey: recentsKey)
    }

    /// 命令行的检索行：最近使用在前，其余保持目录顺序（显式 order 键，
    /// 不押 Swift sort 的稳定性）。
    static func orderedCommandRows() -> [PaletteSearch.Row] {
        let recents = recentCommandIDs()
        let ranked = catalog.enumerated().map { index, entry -> (rank: Int, order: Int, row: PaletteSearch.Row) in
            let rank = recents.firstIndex(of: entry.row.id) ?? (recents.count + index)
            return (rank, index, entry.row)
        }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }
            .map(\.row)
    }

    // MARK: - 检索结果

    private var allRows: [PaletteSearch.Row] {
        Self.orderedCommandRows() + sources.tabs + sources.bookmarks
            + sources.history + sources.conversations
    }

    private var sections: [PaletteSearch.Section] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? PaletteSearch.initialSections(rows: allRows)
            : PaletteSearch.search(query, rows: allRows)
    }

    private var items: [PaletteSearch.DisplayItem] {
        PaletteSearch.displayItems(sections)
    }

    /// 键盘只踩行（组头跳过）。
    private var selectable: [PaletteSearch.Row] {
        items.compactMap(\.rowValue)
    }

    private func icon(for row: PaletteSearch.Row) -> String {
        switch row.source {
        case .command:
            return Self.catalog.first { $0.row.id == row.id }?.icon ?? "terminal"
        case .tab: return "rectangle.stack"
        case .bookmark: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        case .conversation: return "bubble.left.and.text.bubble.right"
        }
    }

    private func sourceTitle(_ source: PaletteSearch.Source) -> String {
        switch source {
        case .command: return String(localized: "Commands")
        case .tab: return String(localized: "Open Tabs")
        case .bookmark: return String(localized: "Bookmarks")
        case .history: return String(localized: "History")
        case .conversation: return String(localized: "Conversations")
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands, tabs, bookmarks…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .header(let source, let total):
                                HStack(spacing: 6) {
                                    Text(sourceTitle(source))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(total)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            case .row(let row):
                                rowView(row)
                            }
                        }
                        if selectable.isEmpty {
                            Text(query.isEmpty
                                 ? String(localized: "Nothing to show")
                                 : String(localized: "No matches"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedIndex) { _, index in
                    if selectable.indices.contains(index) {
                        proxy.scrollTo("row-\(selectable[index].source.rawValue)-\(selectable[index].id)",
                                       anchor: .center)
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadowProminent()
        .onAppear {
            sources = makeSources()
            selectedIndex = 0
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                switch event.keyCode {
                case 125 where flags.isEmpty:      // down
                    selectedIndex = min(selectedIndex + 1, selectable.count - 1)
                    return nil
                case 126 where flags.isEmpty:      // up
                    selectedIndex = max(selectedIndex - 1, 0)
                    return nil
                case 36 where flags.isEmpty || flags == .command:   // return / ⌘return
                    if selectable.indices.contains(selectedIndex) {
                        activate(selectable[selectedIndex], newTab: flags == .command)
                    }
                    return nil
                case 53:                            // esc
                    dismiss()
                    return nil
                default:
                    return event
                }
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            self.keyMonitor = nil
        }
    }

    private func rowView(_ row: PaletteSearch.Row) -> some View {
        let index = selectable.firstIndex(of: row) ?? -1
        return HStack(spacing: 10) {
            Image(systemName: icon(for: row))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if row.source == .command {
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(index == selectedIndex ? appAccent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering, index >= 0 { selectedIndex = index }
        }
        .onTapGesture { activate(row, newTab: false) }
        .id("row-\(row.source.rawValue)-\(row.id)")
    }

    private func activate(_ row: PaletteSearch.Row, newTab: Bool) {
        switch row.source {
        case .command:
            if let entry = Self.catalog.first(where: { $0.row.id == row.id }) {
                Self.recordUse(entry.row.id)
                onRun(entry.command)
            }
        case .tab, .bookmark, .history, .conversation:
            onActivate(row, newTab)
        }
        dismiss()
    }
}
