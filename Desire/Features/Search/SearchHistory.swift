import Foundation

struct SearchHistory: Identifiable {
    let id: UUID
    let query: String
    let engine: SearchEngine
    let timestamp: Date

    init(id: UUID = UUID(), query: String, engine: SearchEngine, timestamp: Date = Date()) {
        self.id = id
        self.query = query
        self.engine = engine
        self.timestamp = timestamp
    }
}

// MARK: - Codable
extension SearchHistory: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case query
        case engine
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        query = try container.decode(String.self, forKey: .query)
        engine = try container.decode(SearchEngine.self, forKey: .engine)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(query, forKey: .query)
        try container.encode(engine, forKey: .engine)
        try container.encode(timestamp, forKey: .timestamp)
    }
}