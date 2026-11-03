import SwiftUI

/// 最近关闭标签面板（v0.8.40 扩展）：跨窗口、跨启动的关闭历史，
/// 可搜索、可逐条恢复；⌘⇧T 仍回放当前窗口的最后一条。
struct RecentlyClosedPanel: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var settings: Settings
    @ObservedObject private var store = RecentlyClosedStore.shared
    private let contentBlocker: ContentBlockerStore?
    private let videoAdBlocker: VideoAdBlocker?
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(tabManager: TabManager, settings: Settings,
         contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker?) {
        self.tabManager = tabManager
        self.settings = settings
        self.contentBlocker = contentBlocker
        self.videoAdBlocker = videoAdBlocker
    }

    private var records: [RecentlyClosedEntry] {
        store.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(appAccent)
                Text("Recently Closed Tabs")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(store.entries.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if !store.entries.isEmpty {
                    Button(String(localized: "Clear")) {
                        store.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            TextField(String(localized: "Search closed tabs…"), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()

            if records.isEmpty {
                Text(store.entries.isEmpty
                     ? String(localized: "No recently closed tabs yet")
                     : String(localized: "No matches"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 500)
    }

    private func row(_ record: RecentlyClosedEntry) -> some View {
        Button {
            tabManager.reopen(
                record: TabManager.RecentlyClosedTab(
                    url: record.url,
                    isIncognito: record.isIncognito,
                    containerID: record.containerID),
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker)
            store.remove(record.id)
        } label: {
            HStack(spacing: 8) {
                FaviconView(urlString: record.url, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(record.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if record.isIncognito {
                    Text("Private")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(record.closedAt, style: .relative)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(appAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
