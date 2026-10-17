import Combine
import Foundation

/// 书签死链校验（v0.7.20）：后台逐条探测书签 URL，报告死链与跨站重定向。
///
/// 长任务模式（同阅读摘要/媒体导出）：工具/桥**立刻返回**"已开跑"，完成后
/// 发系统通知 + 会话备注；**绝不自动删任何书签**——报告交给用户点头后再清
///（清理走既有 removeBookmark 路径）。
@MainActor
final class BookmarkLinkChecker: ObservableObject {
    static let shared = BookmarkLinkChecker()

    struct DeadLink: Equatable {
        let title: String
        let url: String
        let reason: String
    }

    struct RedirectNote: Equatable {
        let title: String
        let url: String
        let destination: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var total = 0
    @Published private(set) var checked = 0
    @Published private(set) var dead: [DeadLink] = []
    @Published private(set) var redirected: [RedirectNote] = []
    @Published private(set) var lastReportAt: Date?

    private init() {}

    /// 立刻返回待检数（0 = 没有可检的/已在跑）；`urls` 非空 = 只查这些
    /// （E2E/按批触发用——绝不误碰列表里其它书签）。
    @discardableResult
    func start(store: BookmarkStore, urls: [String] = [], limit: Int, session: AgentSessionStore?) -> Int {
        guard !isRunning else { return 0 }
        let wanted = Set(urls)
        let targets: [(Bookmark, String)] = store.allBookmarks.compactMap { bookmark in
            guard let raw = bookmark.url, !raw.isEmpty,
                  raw.hasPrefix("http") else { return nil }   // file:/javascript: 不是死链问题
            guard wanted.isEmpty || wanted.contains(raw) else { return nil }
            return (bookmark, raw)
        }.prefix(max(1, limit)).map { $0 }
        guard !targets.isEmpty else { return 0 }
        isRunning = true
        total = targets.count
        checked = 0
        dead = []
        redirected = []
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await Self.probeAll(targets.map(\.1))
            var deadList: [DeadLink] = []
            var redirectList: [RedirectNote] = []
            for (index, outcome) in outcomes.enumerated() {
                let (bookmark, url) = targets[index]
                switch outcome {
                case .ok:
                    break
                case .redirected(let destination):
                    redirectList.append(RedirectNote(title: bookmark.title, url: url, destination: destination))
                case .dead(let reason):
                    deadList.append(DeadLink(title: bookmark.title, url: url, reason: reason))
                }
                self.checked = index + 1
            }
            self.dead = deadList
            self.redirected = redirectList
            self.isRunning = false
            self.lastReportAt = Date()

            var lines = ["书签死链校验完成：检查 \(targets.count) 条"]
            lines.append("· 死链 \(deadList.count)" + (deadList.isEmpty ? " ✓" : "："))
            lines.append(contentsOf: deadList.prefix(15).map { "  – \($0.title)（\($0.reason)）\($0.url)" })
            if !redirectList.isEmpty {
                lines.append("· 跨站重定向 \(redirectList.count)（可考虑更新书签地址）：")
                lines.append(contentsOf: redirectList.prefix(10).map { "  – \($0.title) → \($0.destination)" })
            }
            lines.append("（不会自动删除任何书签——要清理请让用户点头）")
            let report = lines.joined(separator: "\n")
            session?.appendExternalNote(report)
            ProactiveNotificationStore.shared.deliver(
                title: "书签死链校验完成",
                body: "检查 \(targets.count) 条：死链 \(deadList.count)、跨站重定向 \(redirectList.count)（未自动删除）",
                tier: .routine)
        }
        return targets.count
    }

    // MARK: - 探测

    enum Outcome: Equatable {
        case ok
        case redirected(String)
        case dead(String)
    }

    /// HEAD 优先（轻量）；HEAD 被拒或网络错 → Range GET 复测一次（有些站
    /// 不认 HEAD）。**不抓正文**（Range bytes=0-0）。超时 8s/资源 12s。
    nonisolated static func probe(_ urlString: String) async -> Outcome {
        guard let url = URL(string: urlString) else { return .dead("invalid URL") }
        func request(_ method: String) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 8
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            if method == "GET" { req.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
            return req
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: request("HEAD"))
            return classify(response: response, original: urlString)
        } catch {
            do {
                let (_, response) = try await session.data(for: request("GET"))
                return classify(response: response, original: urlString)
            } catch let urlError as URLError {
                return .dead("unreachable (\(urlError.code.rawValue))")
            } catch {
                return .dead("unreachable")
            }
        }
    }

    /// 2xx/3xx（含 URLSession 已跟随的终态）= 可达；**401/403 不算死链**
    ///（存在但需权限/被反爬拦——误伤比漏报更扰人）；404/410/5xx/其它 = 死。
    /// 终态 origin 与原始不同 = 跨站重定向（同站跳转/补斜杠不报）。
    nonisolated static func classify(response: URLResponse, original: String) -> Outcome {
        guard let http = response as? HTTPURLResponse else { return .dead("no HTTP response") }
        let status = http.statusCode
        switch status {
        case 200...399:
            if let finalURL = http.url?.absoluteString,
               let originalURL = URL(string: original),
               let finalURLParsed = URL(string: finalURL),
               origin(of: finalURLParsed) != origin(of: originalURL) {
                return .redirected(finalURL)
            }
            return .ok
        case 401, 403:
            return .ok
        default:
            return .dead("HTTP \(status)")
        }
    }

    nonisolated static func origin(of url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? -1)"
    }

    /// 4 并发有界 TaskGroup；结果按原序对齐。
    nonisolated static func probeAll(_ urls: [String]) async -> [Outcome] {
        var results = [Outcome?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            let width = min(4, urls.count)
            for _ in 0..<width {
                let index = next
                next += 1
                group.addTask { (index, await probe(urls[index])) }
            }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                if next < urls.count {
                    let i = next
                    next += 1
                    group.addTask { (i, await probe(urls[i])) }
                }
            }
        }
        return results.map { $0 ?? .dead("skipped") }
    }
}
