import Foundation

/// URL 结构解析——纯逻辑。
nonisolated enum URLParseCore {
    struct Info: Sendable {
        var scheme: String
        var user: String
        var host: String
        var port: Int?
        var path: String
        var query: [(name: String, value: String)]
        var fragment: String
    }

    static func parse(_ raw: String) -> Info? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate), let host = components.host else {
            return nil
        }
        let items = (components.queryItems ?? []).map { item in
            (name: item.name, value: item.value ?? "")
        }
        return Info(scheme: components.scheme ?? "",
                    user: components.user ?? "",
                    host: host,
                    port: components.port,
                    path: components.path,
                    query: items,
                    fragment: components.fragment ?? "")
    }
}
