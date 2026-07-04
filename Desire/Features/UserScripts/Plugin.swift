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

    init(id: UUID = UUID(), name: String, description: String = "", version: String = "1.0", author: String = "", urlPatterns: [String] = ["*"], excludePatterns: [String] = [], runAt: RunAt = .documentEnd, jsCode: String = "", cssCode: String = "", isEnabled: Bool = true, createdAt: Date = Date()) {
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
    }
}

enum RunAt: String, Codable, CaseIterable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"
}
