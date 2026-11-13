import Combine
import Foundation

/// 内置页面体系（v0.8.27）：`desire://<page>[/<param>?query]`。
/// - 标签内渲染页：tools / about / newtab / fallback（未知 host 兜底）
/// - 面板唤起页：settings(+section) / history / bookmarks / downloads /
///   passwords / plugins / agent(+new|<id>) / whiteboard(?text=) /
///   whatsnew / search(?q=) / sync
/// 地址栏、桥 `/navigate` `/new-tab` `/open-url`、系统 open URL 与菜单共用。
enum InternalPageKind: String, CaseIterable, Sendable {
    case tools
    case books
    case about
    case newtab
    case fallback
    case settings
    case history
    case bookmarks
    case downloads
    case passwords
    case plugins
    case agent
    case whiteboard
    case whatsnew
    case search
    case sync
    case research
    case artifacts

    /// 首页/索引里展示的顺序（fallback 不列）。
    static let all: [InternalPageKind] = [
        .tools, .books, .about, .newtab, .settings, .search, .agent,
        .history, .bookmarks, .downloads, .passwords, .plugins,
        .whiteboard, .whatsnew, .sync, .research, .artifacts,
    ]

    var isRenderedInTab: Bool {
        switch self {
        case .tools, .books, .about, .newtab, .fallback, .research: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .tools: return String(localized: "Toolbox")
        case .books: return String(localized: "Books")
        case .about: return String(localized: "About Desire")
        case .newtab: return String(localized: "New Tab")
        case .fallback: return String(localized: "Internal Pages")
        case .settings, .sync: return String(localized: "Settings")
        case .history: return String(localized: "History")
        case .bookmarks: return String(localized: "Bookmarks")
        case .downloads: return String(localized: "Downloads")
        case .passwords: return String(localized: "Password Manager")
        case .plugins: return String(localized: "Plugins")
        case .agent: return String(localized: "Agent")
        case .whiteboard: return String(localized: "Whiteboard")
        case .whatsnew: return String(localized: "What's New")
        case .search: return String(localized: "Search Everywhere")
        case .research: return String(localized: "Research briefs")
        case .artifacts: return String(localized: "Artifacts")
        }
    }

    var icon: String {
        switch self {
        case .tools: return "wrench.and.screwdriver.fill"
        case .books: return "books.vertical"
        case .about: return "info.circle"
        case .newtab: return "plus.square.on.square"
        case .fallback: return "questionmark.square"
        case .settings, .sync: return "gearshape"
        case .history: return "clock"
        case .bookmarks: return "bookmark"
        case .downloads: return "arrow.down.circle"
        case .passwords: return "key"
        case .plugins: return "puzzlepiece"
        case .agent: return "bubble.left.and.text.bubble.right"
        case .whiteboard: return "rectangle.dashed"
        case .whatsnew: return "sparkles"
        case .search: return "magnifyingglass"
        case .research: return "doc.text.magnifyingglass"
        case .artifacts: return "shippingbox"
        }
    }
}

struct InternalDestination {
    var page: InternalPageKind
    var param: String?
    var query: [String: String]
    var urlString: String

    static func tools(param: String? = nil) -> InternalDestination {
        InternalDestination(page: .tools, param: param, query: [:],
                            urlString: "desire://tools" + (param.map { "/\($0)" } ?? ""))
    }
}

@MainActor
enum InternalPages {
    static let scheme = "desire"

    /// 解析内置 URL；非 desire:// 返回 nil。未知 host 落 `.fallback` 兜底页。
    static func parse(_ raw: String?) -> InternalDestination? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == scheme,
              url.host?.isEmpty == false else { return nil }
        let host = url.host!.lowercased()
        let page = InternalPageKind(rawValue: host) ?? .fallback
        let param = url.pathComponents.dropFirst().first?.lowercased()
        var query: [String: String] = [:]
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                query[item.name.lowercased()] = item.value ?? ""
            }
        }
        let canonical = "desire://" + page.rawValue
            + (param.map { "/\($0)" } ?? "")
        return InternalDestination(page: page, param: param, query: query, urlString: canonical)
    }

    /// 入口：按页面类型分派（标签内页需要 tab，面板页忽略）。
    static func open(_ destination: InternalDestination, in tab: Tab?) {
        switch destination.page {
        case .tools:
            guard let tab else { return }
            openTools(destination, in: tab)
        case .books:
            guard let tab else { return }
            showInTab(.books, in: tab, urlString: destination.urlString)
            if let param = destination.param, let id = UUID(uuidString: param) {
                tab.browser.ebookViewerBookID = id
                tab.browser.ebookViewerInitialQuery = nil
                if let raw = destination.query["chapter"], let chapter = Int(raw) {
                    tab.browser.ebookViewerInitialChapter = max(0, chapter)
                } else {
                    tab.browser.ebookViewerInitialChapter = nil
                }
            }
        case .about, .fallback:
            guard let tab else { return }
            showInTab(destination.page, in: tab, urlString: destination.urlString)
        case .research:
            guard let tab else { return }
            showInTab(.research, in: tab, urlString: destination.urlString)
        case .newtab:
            guard let tab else { return }
            tab.browser.closeAllViewers()
            tab.isOnToolsPage = false
            tab.browser.internalPage = nil
            tab.isOnNewTabPage = true
            tab.urlString = "desire://newtab"
        case .settings, .sync:
            var section = SettingsView.Section.sync
            if destination.page == .settings {
                if let param = destination.param, let match = SettingsView.Section(rawValue: param) {
                    section = match
                } else {
                    section = .general
                }
            }
            SettingsView.SettingsSectionNavigator.shared.selected = section
            CommandBus.shared.send(.showSettings)
        case .history: CommandBus.shared.send(.showHistory)
        case .bookmarks: CommandBus.shared.send(.showBookmarks)
        case .downloads: CommandBus.shared.send(.showDownloads)
        case .passwords: CommandBus.shared.send(.showPasswordManager)
        case .plugins: CommandBus.shared.send(.showPlugins)
        case .whatsnew: WhatsNewStore.shared.show()
        case .artifacts:
            NotificationCenter.default.post(name: .openArtifactsPanel, object: nil)
        case .search:
            let q = destination.query["q"] ?? destination.param ?? ""
            if !q.isEmpty {
                RelatedSearchCenter.shared.request(q, semantic: false)
            }
            AppState.live?.showSearchEverywhere = true
        case .whiteboard:
            if let text = destination.query["text"], !text.isEmpty {
                WhiteboardStore.shared.append(
                    [WhiteboardBlock(type: WhiteboardBlock.Kind.note,
                                     title: String(localized: "Quick capture"),
                                     content: String(text.prefix(2200)))],
                    title: nil,
                    conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
            }
            WhiteboardPanel.shared.show()
        case .agent:
            if let param = destination.param, param != "new",
               let id = UUID(uuidString: param) {
                AgentScheduler.shared.deliveryTarget?.loadConversation(id)
            }
            NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
        }
    }

    /// 外部/桥入口：标签内页开新标签，面板页直接唤起。
    static func openAnywhere(_ destination: InternalDestination) {
        if destination.page.isRenderedInTab {
            guard let manager = TabSessionCoordinator.shared.activeTabManager else { return }
            if let selected = manager.selectedTab, selected.isOnNewTabPage {
                open(destination, in: selected)
                return
            }
            let existing = Set(manager.tabs.map(\.id))
            manager.addTab(makeActive: true)
            if let created = manager.tabs.first(where: { !existing.contains($0.id) }) {
                open(destination, in: created)
            }
            return
        }
        open(destination, in: nil)
    }

    static func destination(for page: InternalPageKind) -> InternalDestination {
        InternalDestination(page: page, param: nil, query: [:],
                            urlString: "desire://\(page.rawValue)")
    }

    static func close(in tab: Tab) {
        tab.isOnToolsPage = false
        tab.toolsPageSelection = nil
        tab.browser.internalPage = nil
    }

    // MARK: - 私有

    private static func openTools(_ destination: InternalDestination, in tab: Tab) {
        tab.browser.closeAllViewers()
        tab.isOnNewTabPage = false
        tab.isOnToolsPage = true
        tab.browser.internalPage = nil
        tab.toolsPageSelection = destination.param
        // VideoPro：编辑器会话挂标签（切走标签不销毁工程、可被命令路由）。
        // 工具页内点卡片也要能拿到，所以进工具页就建（每个工具页标签一个）。
        tab.browser.ensureVideoProStore()
        if let text = destination.query["text"], !text.isEmpty,
           let tool = ToolboxLauncher.matchTool(destination.param) {
            ToolboxHandoff.shared.setPendingText(text, for: tool)
        }
        tab.urlString = destination.urlString
        tab.displayTitle = String(localized: "Toolbox")
        tab.browser.pageTitle = String(localized: "Toolbox")
    }

    private static func showInTab(_ page: InternalPageKind, in tab: Tab, urlString: String) {
        tab.browser.closeAllViewers()
        tab.isOnToolsPage = false
        tab.toolsPageSelection = nil
        tab.browser.internalPage = page
        tab.isOnNewTabPage = false
        tab.urlString = urlString
        tab.displayTitle = page.title
        tab.browser.pageTitle = page.title
    }
}

extension BrowserState {
    /// 关闭所有"查看器/阅读模式/内置页"覆盖层。
    func closeAllViewers() {
        pdfViewerURL = nil
        pdfViewerSourceKey = nil
        pdfViewerReturnURL = nil
        mediaViewerURL = nil
        mediaPlayerImmersive = false
        spreadsheetViewerURL = nil
        imageEditorURL = nil
        imageEditorSession = nil
        archiveViewerURL = nil
        documentViewerURL = nil
        jsonViewerURL = nil
        presentationViewerURL = nil
        internalPage = nil
        ebookViewerBookID = nil
        ebookViewerFileURL = nil
        isReadingMode = false
        isReaderLoading = false
        isPDFLoading = false
    }
}
