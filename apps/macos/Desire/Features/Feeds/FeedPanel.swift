import SwiftUI
import UniformTypeIdentifiers

/// 订阅面板（v0.8.45 批 2）：左侧源列表（未读徽标）+ 右侧文章列表。
/// 点击文章 → 当前标签阅读模式打开；右键星标/已读切换；全部刷新/全部已读。
/// 数据走 FeedStore.shared（@ObservedObject），抓取走 FeedFetcher.shared。
struct FeedsPanel: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = FeedStore.shared
    @State private var selectedFeedURL: String?
    @State private var isRefreshing = false
    @State private var flash: String?
    // 丰富批（批 5）：搜索过滤 + 只看未读/星标 + OPML 导入导出
    @State private var searchText = ""
    @State private var unreadOnly = false
    @State private var starredOnly = false
    @State private var showImporter = false

    let onClose: () -> Void
    /// 文章点击（当前标签阅读模式打开）
    let onOpen: (String) -> Void
    /// 右键"在浏览器打开"（不进阅读模式）
    var onOpenInTab: ((String) -> Void)? = nil

    private var articles: [FeedItem] {
        var list = store.articles(for: selectedFeedURL)
        if unreadOnly { list = list.filter { !$0.isRead } }
        if starredOnly { list = list.filter(\.isStarred) }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || ($0.summary?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.feeds.isEmpty {
                emptyState
            } else {
                filterBar
                Divider()
                HStack(spacing: 0) {
                    feedList
                        .frame(width: 220)
                    Divider()
                    articleList
                }
            }
        }
        .frame(width: 820, height: 580)
        .sheet(isPresented: $showImporter) {
            importerSheet
        }
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
            // 刷新间隔（丰富批）：5 档，立即重排定时器
            Menu {
                ForEach([15.0, 30.0, 60.0, 120.0, 240.0], id: \.self) { minutes in
                    Button(intervalLabel(minutes)) {
                        FeedFetcher.shared.applyRefreshInterval(minutes: minutes)
                    }
                }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("Refresh Interval")
            Menu {
                Button(String(localized: "Export OPML…")) { exportOPML() }
                Button(String(localized: "Import OPML…")) { showImporter = true }
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("OPML")
            Button(String(localized: "Done")) { onClose() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func intervalLabel(_ minutes: Double) -> String {
        minutes >= 60
            ? String(localized: "\(Int(minutes / 60)) hour(s)")
            : String(localized: "\(Int(minutes)) min")
    }

    // MARK: - 过滤条

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(String(localized: "Search articles"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            chip(String(localized: "Unread"), active: unreadOnly) {
                unreadOnly.toggle()
            }
            chip(String(localized: "Starred"), active: starredOnly) {
                starredOnly.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(active
                    ? AnyShapeStyle(appAccent.opacity(0.15))
                    : AnyShapeStyle(Color.secondary.opacity(0.1))))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? appAccent : Color.secondary)
    }

    // MARK: - OPML

    @State private var opmlNote: String?

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "desire-feeds.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let xml = FeedOPMLCore.export(feeds: store.feeds)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            flash = String(localized: "Exported OPML")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                flash = nil
            }
        } catch {
            flash = error.localizedDescription
        }
    }

    private func importOPML(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let entries = FeedOPMLCore.importEntries(from: data) else {
            flash = String(localized: "Could not read the OPML file")
            return
        }
        guard entries.isEmpty == false else {
            flash = String(localized: "The OPML file has no subscriptions")
            return
        }
        for entry in entries where store.feed(url: entry.url) == nil {
            _ = store.addFeed(url: entry.url, title: entry.title,
                              siteURL: entry.siteURL,
                              feedDescription: nil)
        }
        flash = String(localized: "Imported \(entries.count) subscription(s)")
        Task { @MainActor in
            _ = await FeedFetcher.shared.fetchAll()
        }
    }

    private var importerSheet: some View {
        VStack(spacing: 10) {
            Text(String(localized: "Import OPML"))
                .font(.system(size: 13, weight: .semibold))
            Button(String(localized: "Choose File…")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                if let type = UTType(filenameExtension: "opml") {
                    panel.allowedContentTypes = [type]
                }
                if panel.runModal() == .OK, let url = panel.url {
                    importOPML(from: url)
                }
                showImporter = false
            }
            .buttonStyle(.borderedProminent)
            Button(String(localized: "Cancel")) { showImporter = false }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 320)
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
                if let url {
                    FaviconView(urlString: url, size: 13)
                        .frame(width: 14, height: 14)
                }
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
            if let url {
                Button(String(localized: "Mark All as Read")) {
                    store.markAllRead(feedURL: url)
                }
                Button(store.feed(url: url)?.urgentNotifications == true
                       ? String(localized: "Routine notifications")
                       : String(localized: "Urgent notifications")) {
                    let currentlyUrgent = store.feed(url: url)?.urgentNotifications == true
                    store.setUrgentNotifications(url, enabled: currentlyUrgent ? nil : true)
                }
                Divider()
                Button(String(localized: "Unsubscribe"), role: .destructive) {
                    store.removeFeed(url: url)
                    if selectedFeedURL == url { selectedFeedURL = nil }
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
            if let link = article.link {
                Button(String(localized: "Open in Browser")) {
                    onOpenInTab?(link)
                }
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
