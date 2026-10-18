import Foundation

/// 命令面板（v0.7.21 混合检索）在 ContentView 侧的接线：四源快照构建 +
/// 行激活路由（选中标签 / 打开 URL / 载入会话）。抽出成独立文件让
/// ContentView.swift 保持组合根尺寸（同 ContentView+Toolbar 惯例）。
extension ContentView {

    /// 打开面板时快照一次（面板短命，不做实时观察）。
    func makePaletteSources() -> CommandPalette.DataSources {
        let rows = PaletteSnapshot.rows(
            tabManager: tabManager,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            conversationStore: conversationStore
        )
        var sources = CommandPalette.DataSources()
        for row in rows {
            switch row.source {
            case .tab: sources.tabs.append(row)
            case .bookmark: sources.bookmarks.append(row)
            case .history: sources.history.append(row)
            case .conversation: sources.conversations.append(row)
            case .command: break
            }
        }
        return sources
    }

    /// 面板行激活：回车/⌘回车（newTab）。
    func activatePaletteRow(_ row: PaletteSearch.Row, newTab: Bool) {
        switch row.source {
        case .tab:
            if newTab, let url = row.url {
                openInNewTab(url)
            } else if let id = UUID(uuidString: row.id),
                      let index = tabManager.tabs.firstIndex(where: { $0.id == id }) {
                tabManager.selectTab(at: index)
            }
        case .bookmark, .history:
            guard let url = row.url else { return }
            if newTab {
                openInNewTab(url)
            } else if let tab = tabManager.selectedTab {
                navigateToURL(url, for: tab)
            }
        case .conversation:
            if let id = UUID(uuidString: row.id) {
                aiSession.loadConversation(id)
                showAgentPanel = true
            }
        case .command:
            break   // 命令行在面板内部直接走 onRun
        }
    }

    private func openInNewTab(_ url: String) {
        tabManager.addTab(url: url,
                          javaScriptEnabled: settings.isJavaScriptEnabled,
                          contentBlocker: contentBlocker,
                          videoAdBlocker: videoAdBlocker,
                          autoPlayPolicy: settings.autoPlayPolicy,
                          newTabPosition: settings.newTabPosition,
                          makeActive: true)
    }
}
