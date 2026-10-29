import Foundation

/// 混合模式的**工具目标规则**（v0.8.23）：用户窗口里的 Agent 会话默认作用于
/// Agent 角色窗口，而不是用户正在看的标签——这是"互不干扰"的关键一条。
///
/// 包装而不是改写 `WindowToolSurface`：只替换 `tabManager`，其余依赖照旧
/// 转发。Agent 窗口自己的会话不包装（它本来就指向自己）。
@MainActor
final class ModeAwareToolSurface: BrowserToolSurface {
    private let base: any BrowserToolSurface
    let tabManager: TabManager?

    init(base: any BrowserToolSurface, tabManager: TabManager) {
        self.base = base
        self.tabManager = tabManager
    }

    var bookmarkStore: BookmarkStore { base.bookmarkStore }
    var historyStore: HistoryStore { base.historyStore }
    var contentBlocker: ContentBlockerStore { base.contentBlocker }
    var readingListStore: ReadingListStore { base.readingListStore }
    var downloadStore: DownloadStore { base.downloadStore }
    var siteSettingsStore: SiteSettingsStore { base.siteSettingsStore }
    var settings: Settings { base.settings }
    var videoAdBlocker: VideoAdBlocker { base.videoAdBlocker }
    var pluginStore: PluginStore { base.pluginStore }
    var elementBlockStore: ElementBlockStore { base.elementBlockStore }
    var tabGroupStore: TabGroupStore { base.tabGroupStore }
    var quickDialStore: QuickDialStore { base.quickDialStore }
    var agentPreference: AgentPreferenceStore { base.agentPreference }
    var passwordStore: PasswordStore { base.passwordStore }
    var conversationStore: ConversationStore { base.conversationStore }
    var devToolsStore: DevToolsStore { base.devToolsStore }
}
