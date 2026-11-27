import Foundation

/// 泄露检查的网络层（v0.8.80）：**只在用户显式点击"检查泄露"时调用**——不做后台
/// 自动扫描、不在启动时联网。按 SHA-1 前缀分组请求（同前缀只发一次），每个前缀
/// 失败独立计数，**失败不等于安全**（面板会如实说"N 组没查成"）。
@MainActor
enum PasswordBreachService {
    struct Item: Sendable {
        let id: UUID
        let password: String
    }

    struct Outcome: Equatable {
        /// 条目 id → 已知泄露次数（未收录的不在里面）。
        var counts: [UUID: Int]
        /// 请求失败的前缀组数。
        var failedGroups: Int
    }

    static func check(_ items: [Item],
                      endpoint: URL = PasswordBreach.defaultBase,
                      session: URLSession = .shared) async -> Outcome {
        var byPrefix: [String: [Item]] = [:]
        for item in items where !item.password.isEmpty {
            byPrefix[PasswordBreach.prefix(of: item.password), default: []].append(item)
        }
        var counts: [UUID: Int] = [:]
        var failed = 0
        for (prefix, group) in byPrefix {
            var request = URLRequest(url: endpoint.appendingPathComponent("range").appendingPathComponent(prefix))
            request.timeoutInterval = 15
            request.setValue("Desire-Password-Health", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8) else {
                    failed += 1
                    continue
                }
                for item in group {
                    if let count = PasswordBreach.breachCount(for: item.password, rangeResponse: text) {
                        counts[item.id] = count
                    }
                }
            } catch {
                failed += 1
            }
        }
        return Outcome(counts: counts, failedGroups: failed)
    }
}
