import Foundation
import os

/// Feed 抓取器（v0.8.45 批 2）：并行逐源抓取（单源失败退避不拖垮全队列）、
/// 条件请求（ETag/Last-Modified → 304 静默）、定时刷新（默认 30 分钟，可配）。
/// 订阅时的首次抓取也走这里（标题从 feed 元数据回填）。
@MainActor
final class FeedFetcher {
    static let shared = FeedFetcher()

    private static let refreshMinutesKey = "feeds.refreshMinutes"

    private let session: URLSession
    /// 每源退避（分钟）：失败翻倍、6h 封顶；成功清零。
    private var backoffMinutes: [String: Double] = [:]
    /// 下次允许尝试时间（退避期间 fetchAll 跳过）
    private var nextAttempt: [String: Date] = [:]
    private var timer: Timer?
    private(set) var isRefreshing = false

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// 启动定时刷新（AppState.init 调用）。
    func startTimer() {
        guard timer == nil else { return }
        scheduleTimer()
    }

    private func scheduleTimer() {
        let minutes = refreshIntervalMinutes
        // Timer + MainActor.assumeIsolated 在本机是已知 PAC 崩溃形态
        //（SerialExecutor EXC_BAD_ACCESS，回调偶发非主线程 fire）——
        // 一律 Task @MainActor 跳帧（2026-11-10 崩溃报告实证）。
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.fetchAll()
            }
        }
    }

    var refreshIntervalMinutes: Double {
        let stored = UserDefaults.standard.double(forKey: Self.refreshMinutesKey)
        return stored >= 5 && stored <= 1_440 ? stored : 30
    }
    /// 面板改刷新间隔：落盘 + 立即重排定时器。
    func applyRefreshInterval(minutes: Double) {
        guard minutes >= 5, minutes <= 1_440 else { return }
        UserDefaults.standard.set(minutes, forKey: Self.refreshMinutesKey)
        scheduleTimer()
    }

    // MARK: - 抓取

    /// 全量刷新：并行逐源（退避期内的源跳过），返回新增文章总数。
    @discardableResult
    func fetchAll() async -> Int {
        guard isRefreshing == false else { return 0 }
        isRefreshing = true
        defer { isRefreshing = false }
        let store = FeedStore.shared
        let now = Date()
        let due = store.feeds.filter { feed in
            (nextAttempt[feed.url] ?? .distantPast) <= now
        }
        guard due.isEmpty == false else { return 0 }
        let results = await withTaskGroup(of: (String, Int).self) { group in
            for feed in due {
                group.addTask { [weak self] in
                    let count = await self?.fetch(feed: feed) ?? 0
                    return (feed.url, count)
                }
            }
            var total = 0
            var perFeed: [(url: String, count: Int)] = []
            for await (url, count) in group {
                total += count
                if count > 0 {
                    perFeed.append((url, count))
                }
            }
            if total > 0 {
                Log.agent.info("feeds refreshed: +\(total) new article(s) across \(due.count) feed(s)")
                deliverNewArticlesNotification(perFeed: perFeed, total: total)
            }
            return total
        }
        return results
    }

    /// 新文章通知（v0.8.45）：routine 级（免打扰/预算门控照旧）；任何
    /// `urgentNotifications` 源有新增 → 整条升 urgent 直推。
    private func deliverNewArticlesNotification(perFeed: [(url: String, count: Int)],
                                                total: Int) {
        let store = FeedStore.shared
        let urgent = perFeed.contains { pair in
            store.feed(url: pair.url)?.urgentNotifications == true
        }
        let sources = perFeed.compactMap { store.feed(url: $0.url)?.title }
            .prefix(3).joined(separator: "、")
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Feeds updated"),
            body: sources.isEmpty
                ? String(localized: "\(total) new article(s) in your subscriptions")
                : String(localized: "\(total) new article(s)：\(sources)"),
            tier: urgent ? .urgent : .routine)

    }

    /// 抓单个源；返回新增文章数。
    @discardableResult
    func fetch(feed: Feed) async -> Int {
        let store = FeedStore.shared
        guard store.feed(url: feed.url) != nil else { return 0 }
        var request = URLRequest(url: URL(string: feed.url) ?? URL(fileURLWithPath: "/"))
        if let etag = feed.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = feed.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            switch http.statusCode {
            case 200:
                let fetchedAt = Date()
                guard let parsed = FeedCore.parse(data: data, fetchedAt: fetchedAt) else {
                    registerFailure(feed.url)
                    store.applyFetch(feedURL: feed.url, meta: nil, drafts: [],
                                     etag: nil, lastModified: nil,
                                     error: String(localized: "Feed format not recognized"))
                    return 0
                }
                clearBackoff(feed.url)
                let newCount = store.applyFetch(
                    feedURL: feed.url, meta: parsed.meta, drafts: parsed.items,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                    error: nil)
                return newCount
            case 304:
                // 未变化：只刷新抓取时间
                clearBackoff(feed.url)
                store.applyFetch(feedURL: feed.url, meta: nil, drafts: [],
                                 etag: nil, lastModified: nil, error: nil)
                return 0
            default:
                registerFailure(feed.url)
                store.applyFetch(feedURL: feed.url, meta: nil, drafts: [],
                                 etag: nil, lastModified: nil,
                                 error: "HTTP \(http.statusCode)")
                return 0
            }
        } catch {
            registerFailure(feed.url)
            store.applyFetch(feedURL: feed.url, meta: nil, drafts: [],
                             etag: nil, lastModified: nil,
                             error: error.localizedDescription)
            return 0
        }
    }

    /// 订阅并立即首抓（工具栏/Agent 共用入口）。
    @discardableResult
    func subscribeAndFetch(url: String) -> Bool {
        guard URL(string: url) != nil else { return false }
        _ = FeedStore.shared.addFeed(url: url, title: "", siteURL: nil,
                                     feedDescription: nil)
        Task {
            await fetchAll()
        }
        return true
    }

    // MARK: - 退避

    private func registerFailure(_ url: String) {
        let previous = backoffMinutes[url] ?? 5
        let doubled = min(previous * 2, 360)
        backoffMinutes[url] = doubled
        nextAttempt[url] = Date().addingTimeInterval(doubled * 60)
    }

    private func clearBackoff(_ url: String) {
        backoffMinutes.removeValue(forKey: url)
        nextAttempt.removeValue(forKey: url)
    }
}
