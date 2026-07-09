import Foundation

struct ConsoleMessage: Identifiable {
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

// MARK: - Codable
extension ConsoleMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case level
        case message
        case timestamp
        case url
        case line
        case column
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        level = try container.decode(Level.self, forKey: .level)
        message = try container.decode(String.self, forKey: .message)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        column = try container.decodeIfPresent(Int.self, forKey: .column)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(level, forKey: .level)
        try container.encode(message, forKey: .message)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(column, forKey: .column)
    }
}