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
                Text("Bookmarks").font(.headline)
                Spacer()
                Button("", systemImage: "square.and.arrow.up") { store.exportToHTML() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Export")
                Menu {
                    ForEach(BookmarkImportService.ImportSource.allCases) { source in
                        Button {
                            importFrom(source)
                        } label: {
                            Label(source.displayName, systemImage: source.icon)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .help("Import")
                Button("", systemImage: "folder.badge.plus") { showNewFolder = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("New Folder")
                Button("Close", action: onClose)
            }
            .padding()

            if !store.bookmarks.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Bookmarks…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if flatItems.isEmpty {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Bookmarks") : String(localized: "No Matching Bookmarks"))
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
                                        Button("Open in New Tab") { onSelect(url) }
                                        Button("Copy Link") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(url, forType: .string)
                                        }
                                        Divider()
                                        Button("Edit…") { startEditing(item.bookmark) }
                                        Button("Delete", role: .destructive) { onDelete(item.bookmark) }
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
                                        Button("Edit Folder…") { startEditing(item.bookmark) }
                                        Button("Delete Folder", role: .destructive) { onDelete(item.bookmark) }
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
                Text("New Folder").font(.headline)
                TextField("Folder Name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button("Cancel") {
                        newFolderName = ""
                        showNewFolder = false
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("Create") {
                        let name = newFolderName.trimmingCharacters(in: .whitespaces)
                        store.addFolder(title: name.isEmpty ? String(localized: "New Folder") : name)
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

    private func importFrom(_ source: BookmarkImportService.ImportSource) {
        guard let bookmarks = BookmarkImportService.importBookmarks(from: source),
              !bookmarks.isEmpty else { return }
        store.saveImported(bookmarks)
    }
}

private struct BookmarkEditor: View {
    @State var bookmark: Bookmark
    let onSave: (Bookmark) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(bookmark.isFolder ? "Edit Folder" : "Edit Bookmark").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $bookmark.title)
                    .textFieldStyle(.roundedBorder)
            }

            if bookmark.isLeaf {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(.caption).foregroundStyle(.secondary)
                    TextField("URL", text: Binding(
                        get: { bookmark.url ?? "" },
                        set: { bookmark.url = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Save") { onSave(bookmark) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

#Preview {
    BookmarkPanel(store: BookmarkStore(), onSelect: { _ in }, onDelete: { _ in }, onClose: {})
        .frame(width: 420, height: 500)
}
