import Foundation

/// Feed Agent 工具族实现（v0.8.45 批 3）。只读 = listFeeds / readFeedArticles；
/// 写 = subscribeFeed / unsubscribeFeed / markArticleRead。失败统一 `Error: ` 前缀
/// （BrowserToolProvider.fail）。订阅立即首抓（await，模型能直接看到文章）。
extension BrowserToolProvider {

    static func listFeeds(_ args: [String: Any]) -> String {
        let feeds = FeedStore.shared.feeds
        guard feeds.isEmpty == false else {
            return String(localized: "No feed subscriptions yet. subscribeFeed can add one.")
        }
        return feeds.map { feed in
            let unread = FeedStore.shared.unreadCount(for: feed.url)
            return "• \(feed.title) — \(feed.url) (\(unread) unread)"
        }.joined(separator: "\n")
    }

    static func readFeedArticles(_ args: [String: Any]) async -> String {
        let feedURL = args["feedUrl"] as? String
        let unreadOnly = (args["unreadOnly"] as? Bool) ?? false
        let articles = FeedStore.shared.articles(for: feedURL, unreadOnly: unreadOnly)
        guard articles.isEmpty == false else {
            if let feedURL, FeedStore.shared.feed(url: feedURL) == nil {
                return fail("No subscription for \(feedURL)")
            }
            return String(localized: "No \(unreadOnly ? "unread " : "")articles.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        var out = String(localized: "Showing the \(min(articles.count, 30)) most recent of \(articles.count) article(s):")
        out += "\n"
        for article in articles.prefix(30) {
            out += "• [\(article.id)] \(article.title)"
            out += " (\(formatter.string(from: article.displayDate))"
            if let link = article.link {
                out += " · \(link)"
            }
            out += ")"
            if let summary = article.summary {
                out += "\n  " + String(summary.prefix(160))
            }
            out += "\n"
        }
        return out
    }

    static func subscribeFeed(_ args: [String: Any]) async -> String {
        guard let urlString = args["url"] as? String,
              urlString.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return fail("Missing url")
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            return fail("Invalid url: \(urlString)")
        }
        if let existing = FeedStore.shared.feed(url: url.absoluteString) {
            return String(localized: "Already subscribed: \(existing.title)")
        }
        let feed = FeedStore.shared.addFeed(url: url.absoluteString, title: "",
                                            siteURL: nil, feedDescription: nil)
        let newCount = await FeedFetcher.shared.fetch(feed: feed)
        let refreshed = FeedStore.shared.feed(url: url.absoluteString) ?? feed
        if let error = refreshed.lastError, !error.isEmpty {
            return fail("Subscribed but the first fetch failed (\(error)). It will retry with backoff.")
        }
        let total = FeedStore.shared.articles(for: url.absoluteString).count
        return String(localized: "Subscribed \(refreshed.title) — \(total) article(s), \(newCount) new. Use readFeedArticles to read them.")
    }

    static func unsubscribeFeed(_ args: [String: Any]) -> String {
        guard let urlString = args["url"] as? String,
              urlString.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return fail("Missing url")
        }
        guard FeedStore.shared.feed(url: urlString) != nil else {
            return fail("No subscription for \(urlString)")
        }
        FeedStore.shared.removeFeed(url: urlString)
        return String(localized: "Unsubscribed \(urlString).")
    }

    static func markArticleRead(_ args: [String: Any]) -> String {
        guard let id = args["guid"] as? String,
              id.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return fail("Missing guid (the [id] shown by readFeedArticles)")
        }
        let read = (args["read"] as? Bool) ?? true
        guard FeedStore.shared.items.contains(where: { $0.id == id }) else {
            return fail("No such article: \(id)")
        }
        FeedStore.shared.markRead(id, read: read)
        return String(localized: "\(read ? "Marked read" : "Marked unread"): \(id)")
    }
}
