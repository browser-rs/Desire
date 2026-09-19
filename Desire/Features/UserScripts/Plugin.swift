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

    init(id: UUID = UUID(), name: String, description: String = "", version: String = "1.0", author: String = "", urlPatterns: [String] = ["*"], excludePatterns: [String] = [], runAt: RunAt = .documentEnd, jsCode: String = "", cssCode: String = "", isEnabled: Bool = true, createdAt: Date = Date(), pinned: Bool? = nil, icon: String? = nil, popupHTML: String? = nil) {
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
    }

    var isPinned: Bool { pinned ?? false }
    var toolbarIcon: String { icon ?? "puzzlepiece" }
}

enum RunAt: String, Codable, CaseIterable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"
}
