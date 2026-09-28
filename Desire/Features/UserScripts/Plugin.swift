import Foundation

struct Plugin: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var version: String
    var author: String
    var urlPatterns: [String]
    var excludePatterns: [String]
    var runAt: RunAt
    var jsCode: String
    var cssCode: String
    var isEnabled: Bool
    var createdAt: Date
    /// 工具栏固定（0.2.17 Chrome 式扩展面板）。Optional = 旧持久化数据
    /// 解码安全（缺键为 nil）。
    var pinned: Bool?
    /// 工具栏/面板图标（SF Symbol 名）。
    var icon: String?
    /// manifest v3 装载的 popup 页 HTML（0.3.3）。nil = 无 popup（点击
    /// 固定图标 = 运行一次）。
    var popupHTML: String?
    /// 扩展包自带的真实图标（PNG 数据，取 manifest icons 最大尺寸）。
    /// nil = 用 SF Symbol（toolbarIcon）。Optional = 旧数据解码安全。
    var iconPNG: Data?
    /// background 脚本（service_worker/scripts 内联）。由
    /// PluginBackgroundRuntime 在应用启动/插件启用时以常驻 headless webview
    /// 运行（contextMenus/tabs 事件等）。nil = 无后台。Optional = 旧数据解码安全。
    var backgroundCode: String?
    /// popup 的文档 origin（取 manifest host_permissions 第一个 https/http 条目）。
    /// 作为 loadHTMLString 的 baseURL——Chrome 扩展页面凭 host_permissions 可
    /// 跨域 fetch，Desire 的 popup 是 about:blank 文档，跨域 fetch 会被 CORS
    /// 拦截（"登录失败: Load failed"）；把文档 origin 设成 API 同源即绕开。
    /// nil = baseURL nil（旧行为）。Optional = 旧数据解码安全。
    var popupBaseOrigin: String?

    init(id: UUID = UUID(), name: String, description: String = "", version: String = "1.0", author: String = "", urlPatterns: [String] = ["*"], excludePatterns: [String] = [], runAt: RunAt = .documentEnd, jsCode: String = "", cssCode: String = "", isEnabled: Bool = true, createdAt: Date = Date(), pinned: Bool? = nil, icon: String? = nil, popupHTML: String? = nil, iconPNG: Data? = nil, popupBaseOrigin: String? = nil, backgroundCode: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.urlPatterns = urlPatterns
        self.excludePatterns = excludePatterns
        self.runAt = runAt
        self.jsCode = jsCode
        self.cssCode = cssCode
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.pinned = pinned
        self.icon = icon
        self.popupHTML = popupHTML
        self.iconPNG = iconPNG
        self.popupBaseOrigin = popupBaseOrigin
        self.backgroundCode = backgroundCode
    }

    var isPinned: Bool { pinned ?? false }
    var toolbarIcon: String { icon ?? "puzzlepiece" }
}

enum RunAt: String, Codable, CaseIterable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"
}
