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
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSelecting = false
    @State private var expandedFolders: Set<UUID> = []

    private var flatItems: [FlatBookmark] {
        guard !searchText.isEmpty else {
            return flattenBookmarks(store.bookmarks, level: 0)
        }
        return store.bookmarks.flatMap { $0.flattened() }.filter { item in
            item.0.title.localizedCaseInsensitiveContains(searchText) ||
            (item.0.url?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.map { FlatBookmark(id: $0.0.id, bookmark: $0.0, level: $0.1) }
    }

    private func flattenBookmarks(_ bookmarks: [Bookmark], level: Int) -> [FlatBookmark] {
        var result: [FlatBookmark] = []
        for bookmark in bookmarks {
            result.append(FlatBookmark(id: bookmark.id, bookmark: bookmark, level: level))
            if bookmark.isFolder && expandedFolders.contains(bookmark.id) {
                result.append(contentsOf: flattenBookmarks(bookmark.children, level: level + 1))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Bookmarks").font(.headline)
                Spacer()

                // Selection mode toggle
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedIDs.removeAll() }
                } label: {
                    Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(isSelecting ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isSelecting ? "Done Selecting" : "Select Multiple")

                if isSelecting && !selectedIDs.isEmpty {
                    Button {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete Selected (\(selectedIDs.count))")
                }

                Divider().frame(height: 16)

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

            // Search
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

            // Content
            if flatItems.isEmpty {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Bookmarks") : String(localized: "No Matching Bookmarks"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(flatItems.enumerated()), id: \.element.id) { _, item in
                            bookmarkRow(item)
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

    @ViewBuilder
    private func bookmarkRow(_ item: FlatBookmark) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Selection checkbox (when in selecting mode)
                if isSelecting {
                    Button {
                        if selectedIDs.contains(item.id) {
                            selectedIDs.remove(item.id)
                        } else {
                            selectedIDs.insert(item.id)
                        }
                    } label: {
                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : .secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }

                // Folder expand/collapse
                if item.bookmark.isFolder && !searchText.isEmpty {
                    Button {
                        if expandedFolders.contains(item.id) {
                            expandedFolders.remove(item.id)
                        } else {
                            expandedFolders.insert(item.id)
                        }
                    } label: {
                        Image(systemName: expandedFolders.contains(item.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let url = item.bookmark.url {
                    FaviconView(urlString: url, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.bookmark.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(url)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                } else {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 14))
                    Text(item.bookmark.title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if !searchText.isEmpty {
                        Text("\(item.bookmark.children.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, CGFloat(item.level * 16 + (isSelecting ? 0 : 8)))
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedIDs.contains(item.id) ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .onTapGesture {
                if isSelecting {
                    if selectedIDs.contains(item.id) {
                        selectedIDs.remove(item.id)
                    } else {
                        selectedIDs.insert(item.id)
                    }
                } else {
                    if let url = item.bookmark.url {
                        onSelect(url)
                    } else if item.bookmark.isFolder {
                        if expandedFolders.contains(item.id) {
                            expandedFolders.remove(item.id)
                        } else {
                            expandedFolders.insert(item.id)
                        }
                    }
                }
            }
            .contextMenu {
                if let url = item.bookmark.url {
                    Button("Open in New Tab") { onSelect(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    Divider()
                }
                Button("Edit…") { startEditing(item.bookmark) }
                Button("Delete", role: .destructive) { onDelete(item.bookmark) }
            }

            Divider()
        }
    }

    private func startEditing(_ bookmark: Bookmark) {
        editingBookmark = bookmark
        showEditor = true
    }

    private func deleteSelected() {
        for id in selectedIDs {
            if let bookmark = store.bookmarks.find(where: { $0.id == id }) {
                store.remove(bookmark)
            }
        }
        selectedIDs.removeAll()
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
