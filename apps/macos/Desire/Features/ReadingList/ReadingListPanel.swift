import SwiftUI

struct ReadingListPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: ReadingListStore
    let onSelect: (String) -> Void
    let onClose: () -> Void
    /// 正在抓离线副本的条目（面板内小指示）。
    @State private var cachingIDs: Set<UUID> = []

    /// 抓离线副本：复用已打开标签（含登录态）或后台加载；完成后落徽标。
    private func cacheNow(_ item: ReadingListItem) {
        guard !cachingIDs.contains(item.id) else { return }
        cachingIDs.insert(item.id)
        Task { @MainActor in
            defer { cachingIDs.remove(item.id) }
            guard let outcome = await ReadingListCache.capture(url: item.url, itemID: item.id) else { return }
            store.setCache(item.id, fileURL: outcome.fileURL)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reading List")
                    .font(.headline)
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear All") { store.clearAll() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Close") { onClose() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
            }
            .padding()

            if store.items.isEmpty {
                EmptyState(message: String(localized: "Reading List is Empty"))
            } else {
                List {
                    ForEach(store.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.isRead ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(item.isRead ? .secondary : appAccent)

                            if cachingIDs.contains(item.id) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 12)
                            } else if store.cacheURL(for: item.id) != nil {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(appAccent.opacity(0.8))
                                    .help(String(localized: "Cached offline copy"))
                            }

                            Button {
                                let url = item.url
                                onSelect(url)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .lineLimit(1)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(item.isRead ? .secondary : .primary)
                                    Text(item.url)
                                        .lineLimit(1)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(item.savedDate, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(item.isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")) { store.toggleRead(item.id) }
                                if let cached = store.cacheURL(for: item.id) {
                                    Button(String(localized: "Open Offline Copy")) {
                                        onSelect("file://\(cached.path)")
                                    }
                                    Button(String(localized: "Remove Offline Cache")) {
                                        store.clearCache(item.id)
                                    }
                                }
                                Button(store.cacheURL(for: item.id) == nil
                                       ? String(localized: "Cache for Offline")
                                       : String(localized: "Re-cache for Offline")) {
                                    cacheNow(item)
                                }
                                Button("Delete") { store.remove(item.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { store.remove(at: $0) }
                }
            }
        }
        .frame(width: 420, height: 400)
    }
}

#Preview {
    ReadingListPanel(store: ReadingListStore(), onSelect: { _ in }, onClose: {})
        .frame(width: 420, height: 400)
}
