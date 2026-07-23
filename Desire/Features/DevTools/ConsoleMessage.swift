import Foundation

struct ConsoleMessage: Identifiable, Codable {
    var id = UUID()
    let level: Level
    let message: String
    let timestamp: Date
    let url: String?
    let line: Int?
    let column: Int?

    enum Level: String, CaseIterable, Codable {
        case log = "log"
        case warn = "warn"
        case error = "error"
        case info = "info"
        case debug = "debug"
    }

    init(level: Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.level = level
        self.message = message
        self.timestamp = Date()
        self.url = url
        self.line = line
        self.column = column
    }
}

