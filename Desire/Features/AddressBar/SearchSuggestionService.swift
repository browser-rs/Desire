import Foundation

@MainActor
class SearchSuggestionService {
    static let shared = SearchSuggestionService()
    private init() {}

    /// Short timeout: a hanging suggest endpoint must not keep stale
    /// suggestions from being replaced for 60s (URLSession's default).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    /// Small LRU keyed by "template|query" — repeated prefixes (the common
    /// typing pattern) stop hitting the network entirely.
    private var cache: [String: [String]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 32

    /// `template` is the ACTIVE engine's suggestion endpoint, already
    /// resolved by the caller (`Settings.effectiveSuggestionURL`, nil when
    /// the engine has none — never a different engine's endpoint).
    func suggestions(for query: String, template: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let key = template + "|" + trimmed
        if let cached = cache[key] {
            return cached
        }
        guard let url = URL(string: template + encoded) else { return [] }

        do {
            let (data, _) = try await Self.session.data(from: url)
            let result = Self.parse(data)
            cache[key] = result
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit, let evicted = cacheOrder.first {
                cacheOrder.removeFirst()
                cache[evicted] = nil
            }
            return result
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
