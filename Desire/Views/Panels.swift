import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("浏览历史").font(.headline)
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()

            if store.entries.isEmpty {
                emptyState("暂无浏览记录")
            } else {
                List(store.entries) { entry in
                    EntryRow(title: entry.title, subtitle: entry.url, action: { onSelect(entry.url) })
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}

struct BookmarkPanel: View {
    @ObservedObject var store: BookmarkStore
    var onSelect: (String) -> Void
    var onDelete: (Bookmark) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("书签").font(.headline)
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()

            if store.bookmarks.isEmpty {
                emptyState("暂无书签")
            } else {
                List(store.bookmarks) { bookmark in
                    HStack {
                        EntryRow(title: bookmark.title, subtitle: bookmark.url, action: { onSelect(bookmark.url) })
                        Spacer()
                        Button("", systemImage: "trash", action: { onDelete(bookmark) })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}

struct UserScriptPanel: View {
    @ObservedObject var store: UserScriptStore
    var onAdd: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("用户脚本").font(.headline)
                Spacer()
                Button("", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                Button("关闭", action: onClose)
            }
            .padding()

            if store.scripts.isEmpty {
                emptyState("暂无用户脚本")
            } else {
                List(store.scripts) { script in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { script.isEnabled },
                            set: { enabled in
                                var s = script
                                s.isEnabled = enabled
                                store.update(s)
                            }
                        )) {
                            entryLabel(title: script.name, subtitle: script.urlPattern)
                        }
                        Spacer()
                        Button("", systemImage: "trash", action: { store.remove(script) })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 420, height: 400)
    }
}

@ViewBuilder
private func emptyState(_ message: String) -> some View {
    VStack {
        Spacer()
        Text(message).foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}

private struct EntryRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            entryLabel(title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
private func entryLabel(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).lineLimit(1).font(.body)
        Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(.secondary)
    }
}
