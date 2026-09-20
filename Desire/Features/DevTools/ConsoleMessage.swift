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

    enum Level: String, CaseIterable, Codable {
        case log = "log"
        case warn = "warn"
        case error = "error"
        case info = "info"
        case debug = "debug"
    }

    init(level: Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil, tabID: UUID? = nil) {
        self.level = level
        self.message = message
        self.timestamp = Date()
        self.url = url
        self.line = line
        self.column = column
        self.tabID = tabID
    }
}

