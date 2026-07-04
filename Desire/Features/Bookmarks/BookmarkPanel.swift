import SwiftUI

struct BookmarkPanel: View {
    @ObservedObject var store: BookmarkStore
    var onSelect: (String) -> Void
    var onDelete: (Bookmark) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var editingBookmark: Bookmark?
    @State private var showEditor = false

    private var filtered: [Bookmark] {
        guard !searchText.isEmpty else { return store.bookmarks }
        return store.bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("书签").font(.headline)
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()

            if !store.bookmarks.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索书签…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if filtered.isEmpty {
                emptyState(searchText.isEmpty ? "暂无书签" : "未找到匹配书签")
            } else {
                List(filtered) { bookmark in
                    EntryRow(
                        title: bookmark.title,
                        subtitle: bookmark.url,
                        action: { onSelect(bookmark.url) }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { onDelete(bookmark) } label: {
                            Image(systemName: "trash")
                        }
                        Button { startEditing(bookmark) } label: {
                            Image(systemName: "pencil")
                        }
                        .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("在新标签页中打开") { onSelect(bookmark.url) }
                        Button("复制链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bookmark.url, forType: .string)
                        }
                        Divider()
                        Button("编辑…") { startEditing(bookmark) }
                        Button("删除", role: .destructive) { onDelete(bookmark) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 500)
        .sheet(isPresented: $showEditor) {
            if let bookmark = editingBookmark {
                BookmarkEditor(bookmark: bookmark) { updated in
                    store.update(updated)
                    showEditor = false
                } onCancel: {
                    showEditor = false
                }
            }
        }
    }

    private func startEditing(_ bookmark: Bookmark) {
        editingBookmark = bookmark
        showEditor = true
    }
}

private struct BookmarkEditor: View {
    @State var bookmark: Bookmark
    let onSave: (Bookmark) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("编辑书签").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("名称", text: $bookmark.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("地址").font(.caption).foregroundStyle(.secondary)
                TextField("地址", text: $bookmark.url)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("保存") { onSave(bookmark) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
