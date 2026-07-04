import SwiftUI

private struct FlatBookmark: Identifiable {
    let id: UUID
    let bookmark: Bookmark
    let level: Int
}

struct BookmarkPanel: View {
    @ObservedObject var store: BookmarkStore
    var onSelect: (String) -> Void
    var onDelete: (Bookmark) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var editingBookmark: Bookmark?
    @State private var showEditor = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private var flatItems: [FlatBookmark] {
        guard !searchText.isEmpty else {
            return store.bookmarks.flatMap { $0.flattened() }.map { FlatBookmark(id: $0.0.id, bookmark: $0.0, level: $0.1) }
        }
        return store.bookmarks.flatMap { $0.flattened() }.filter { item in
            item.0.title.localizedCaseInsensitiveContains(searchText) ||
            (item.0.url?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.map { FlatBookmark(id: $0.0.id, bookmark: $0.0, level: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("书签").font(.headline)
                Spacer()
                Button("", systemImage: "folder.badge.plus") { showNewFolder = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("新建文件夹")
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

            if flatItems.isEmpty {
                emptyState(searchText.isEmpty ? "暂无书签" : "未找到匹配书签")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(flatItems.enumerated()), id: \.element.id) { _, item in
                            VStack(spacing: 0) {
                                if let url = item.bookmark.url {
                                    EntryRow(
                                        title: item.bookmark.title,
                                        subtitle: url,
                                        action: { onSelect(url) }
                                    )
                                    .padding(.leading, CGFloat(item.level * 16))
                                    .contextMenu {
                                        Button("在新标签页中打开") { onSelect(url) }
                                        Button("复制链接") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(url, forType: .string)
                                        }
                                        Divider()
                                        Button("编辑…") { startEditing(item.bookmark) }
                                        Button("删除", role: .destructive) { onDelete(item.bookmark) }
                                    }
                                } else {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.system(size: 13))
                                        Text(item.bookmark.title)
                                            .font(.body)
                                        Spacer()
                                    }
                                    .padding(.leading, CGFloat(item.level * 16))
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("编辑文件夹…") { startEditing(item.bookmark) }
                                        Button("删除文件夹", role: .destructive) { onDelete(item.bookmark) }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
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
        .sheet(isPresented: $showNewFolder) {
            VStack(spacing: 16) {
                Text("新建文件夹").font(.headline)
                TextField("文件夹名称", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button("取消") {
                        newFolderName = ""
                        showNewFolder = false
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("创建") {
                        let name = newFolderName.trimmingCharacters(in: .whitespaces)
                        store.addFolder(title: name.isEmpty ? "新建文件夹" : name)
                        newFolderName = ""
                        showNewFolder = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 300)
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
            Text(bookmark.isFolder ? "编辑文件夹" : "编辑书签").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("名称", text: $bookmark.title)
                    .textFieldStyle(.roundedBorder)
            }

            if bookmark.isLeaf {
                VStack(alignment: .leading, spacing: 4) {
                    Text("地址").font(.caption).foregroundStyle(.secondary)
                    TextField("地址", text: Binding(
                        get: { bookmark.url ?? "" },
                        set: { bookmark.url = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
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
