import Foundation

struct ConsoleMessage: Identifiable, Codable {
    var id = UUID()
    let level: Level
    let message: String
    let timestamp: Date
    let url: String?
    let line: Int?
    let column: Int?
    /// 产生这条消息的标签页。面板的数据源是 app 级共享 store（每个 webview
    /// 都往同一个实例里发消息），靠这个字段按标签页过滤。面板自己发出的行
    /// （REPL 回显）与外部注入的消息可以为 nil。
    let tabID: UUID?
    /// 富文本片段：对象参数带句柄（可点开看属性），其余是纯文本。
    /// `message` 始终是这些片段的纯文本渲染（搜索/折叠/导出都用它）。
    let parts: [Part]?

    /// 消息里的一个片段。
    struct Part: Codable, Hashable {
        /// `text` / `object`。
        let type: String
        let text: String?
        /// 对象句柄（页面侧句柄表里的 key）。
        let ref: String?
        /// 对象的短预览（chip 上显示）。
        let preview: String?

        var isObject: Bool { type == "object" && ref != nil }
    }

    /// 解析消息处理器送来的 `parts` 数组。
    static func parseParts(_ raw: Any?) -> [Part]? {
        guard let list = raw as? [[String: Any]], !list.isEmpty else { return nil }
        let parts: [Part] = list.map { dict in
            Part(
                type: (dict["type"] as? String) ?? "text",
                text: dict["text"] as? String,
                ref: dict["ref"] as? String,
                preview: dict["preview"] as? String
            )
        }
        return parts
    }

    enum Level: String, CaseIterable, Codable {
        case log = "log"
        case warn = "warn"
        case error = "error"
        case info = "info"
        case debug = "debug"
    }

    init(level: Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil, tabID: UUID? = nil, parts: [Part]? = nil) {
        self.level = level
        self.message = message
        self.timestamp = Date()
        self.url = url
        self.line = line
        self.column = column
        self.tabID = tabID
        self.parts = parts
    }
}

