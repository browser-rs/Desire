import Foundation

@MainActor
class SearchSuggestionService {
    static let shared = SearchSuggestionService()
    private init() {}

    func suggestions(for query: String, engine: SearchEngine) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: engine.suggestionURL + encoded) else {
            return []
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return Self.parse(data)
        } catch {
            return []
        }
    }

    private static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        if let array = json as? [Any], array.count >= 2,
           let list = array[1] as? [Any] {
            return list.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let dict = item as? [String: Any], let phrase = dict["phrase"] as? String {
                    return phrase
                }
                return nil
            }
        }
        if let list = json as? [[String: Any]] {
            return list.compactMap { $0["phrase"] as? String }
        }
        return []
    }
}
