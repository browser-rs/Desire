import SwiftUI

/// 订阅面板（v0.8.45 批 2）：左侧源列表（未读徽标）+ 右侧文章列表。
/// 点击文章 → 当前标签阅读模式打开；右键星标/已读切换；全部刷新/全部已读。
/// 数据走 FeedStore.shared（@ObservedObject），抓取走 FeedFetcher.shared。
struct FeedsPanel: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = FeedStore.shared
    @State private var selectedFeedURL: String?
    @State private var isRefreshing = false
    @State private var flash: String?

    let onClose: () -> Void
    /// 文章点击（当前标签阅读模式打开）
    let onOpen: (String) -> Void

    private var articles: [FeedItem] {
        store.articles(for: selectedFeedURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.feeds.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    feedList
                        .frame(width: 220)
                    Divider()
                    articleList
                }
            }
        }
        .frame(width: 820, height: 580)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13))
                .foregroundStyle(appAccent)
            Text(String(localized: "Feeds"))
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: "\(store.unreadCount()) unread")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let flash {
                Text(flash)
                    .font(.system(size: 10.5))
                    .foregroundStyle(appAccent)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Refresh Feeds"))
            Button(String(localized: "Done")) { onClose() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 源列表

    private var feedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                feedRow(title: String(localized: "All Feeds"), url: nil)
                Divider().padding(.vertical, 4)
                ForEach(store.feeds) { feed in
                    feedRow(title: feed.title, url: feed.url,
                            error: feed.lastError)
                }
            }
            .padding(8)
        }
    }

    private func feedRow(title: String, url: String?, error: String? = nil) -> some View {
        let isSelected = selectedFeedURL == url
        let unread = store.unreadCount(for: url)
        return Button {
            selectedFeedURL = url
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(unread > 0 ? appAccent : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? appAccent : .primary)
                    .lineLimit(1)
                Spacer()
                if unread > 0 {
                    Text(verbatim: "\(unread)")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected
                        ? AnyShapeStyle(appAccent.opacity(0.12))
                        : AnyShapeStyle(Color.clear))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if url != nil {
                Button(String(localized: "Mark All as Read"), role: .destructive) {
                    store.markAllRead(feedURL: url)
                }
                Button(String(localized: "Unsubscribe"), role: .destructive) {
                    if let url {
                        store.removeFeed(url: url)
                        if selectedFeedURL == url { selectedFeedURL = nil }
                    }
                }
            }
            if let error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 文章列表

    private var articleList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedFeedURL == nil
                     ? String(localized: "All Feeds")
                     : (store.feed(url: selectedFeedURL ?? "")?.title ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(String(localized: "Mark All as Read")) {
                    store.markAllRead(feedURL: selectedFeedURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.unreadCount(for: selectedFeedURL) == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(articles) { article in
                        articleRow(article)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func articleRow(_ article: FeedItem) -> some View {
        Button {
            store.markRead(article.id)
            if let link = article.link {
                onOpen(link)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(article.isRead ? Color.clear : appAccent)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if article.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(appAccent)
                        }
                        Text(article.title)
                            .font(.system(size: 12, weight: article.isRead ? .regular : .semibold))
                            .foregroundStyle(article.isRead ? Color.secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let summary = article.summary {
                        Text(summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        Text(article.displayDate.formatted(date: .abbreviated,
                                                           time: .shortened))
                        if selectedFeedURL == nil {
                            Text(store.feed(url: article.feedURL)?.title ?? "")
                                .foregroundStyle(appAccent.opacity(0.8))
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(article.isRead
                   ? String(localized: "Mark as Unread")
                   : String(localized: "Mark as Read")) {
                store.markRead(article.id, read: !article.isRead)
            }
            Button(article.isStarred
                   ? String(localized: "Remove Star")
                   : String(localized: "Star Article")) {
                store.toggleStar(article.id)
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No subscriptions yet"))
                .font(.system(size: 13, weight: .medium))
            Text(String(localized: "Open a site with a feed (blog, news) — the toolbar shows a Subscribe action. The Agent can also subscribe for you."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func refresh() {
        guard isRefreshing == false else { return }
        isRefreshing = true
        Task {
            let added = await FeedFetcher.shared.fetchAll()
            isRefreshing = false
            if added > 0 {
                flash = String(localized: "\(added) new article(s)")
                try? await Task.sleep(for: .seconds(2.5))
                flash = nil
            }
        }
    }
}
