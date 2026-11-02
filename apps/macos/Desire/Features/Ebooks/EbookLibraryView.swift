import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 电子书书架（v0.8.34 批次一）：封面网格、搜索、导入、继续阅读。
struct EbookLibraryView: View {
    private enum LibrarySort: String, CaseIterable, Identifiable {
        case recent, added, title, author, progress
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return String(localized: "Recently Read")
            case .added: return String(localized: "Date Added")
            case .title: return String(localized: "Title")
            case .author: return String(localized: "Author")
            case .progress: return String(localized: "Progress")
            }
        }
    }

    @Environment(\.appAccent) private var appAccent: Color
    let onOpen: (Ebook) -> Void
    /// 全库搜索结果打开：书 + 章 + 要高的关键词（v0.8.36）。
    var onOpenAt: ((Ebook, Int, String) -> Void)? = nil

    @ObservedObject private var store = EbookLibraryStore.shared
    @ObservedObject private var stats = ReadingStatsStore.shared
    @State private var query = ""
    @State private var importing = false
    @State private var error: String?
    @State private var note: String?
    @State private var pendingDelete: Ebook?
    @State private var showStats = false
    @State private var showFullTextSearch = false
    @State private var sort: LibrarySort = .recent
    @State private var favoritesOnly = false
    @State private var collectionFilter: String?
    @State private var renaming: Ebook?
    @State private var renameTitle = ""
    @State private var renameAuthor = ""
    @State private var collectionTarget: Ebook?
    @State private var newCollectionName = ""

    private var filtered: [Ebook] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = store.books.filter { book in
            let matchesQuery = needle.isEmpty
                || book.title.lowercased().contains(needle)
                || book.author.lowercased().contains(needle)
                || book.fileName.lowercased().contains(needle)
            let matchesFavorite = !favoritesOnly || book.favorite
            let matchesCollection = collectionFilter == nil
                || book.collectionName == collectionFilter
            return matchesQuery && matchesFavorite && matchesCollection
        }
        return base.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            switch sort {
            case .recent:
                return (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
            case .added:
                return lhs.addedAt > rhs.addedAt
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .author:
                let left = lhs.authorOrUnknown
                let right = rhs.authorOrUnknown
                return left.localizedStandardCompare(right) == .orderedAscending
            case .progress:
                if lhs.progress != rhs.progress { return lhs.progress > rhs.progress }
                return lhs.addedAt > rhs.addedAt
            }
        }
    }

    private var statsSummary: String? {
        let minutes = stats.weekSeconds / 60
        guard minutes > 0 || stats.streakDays > 0 else { return nil }
        return "\(String(localized: "This week")) \(minutes) \(String(localized: "min")) · \(stats.streakDays) \(String(localized: "day streak"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190),
                                                 spacing: 20)],
                              alignment: .leading, spacing: 24) {
                        ForEach(filtered) { book in
                            bookCard(book)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1500, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert(String(localized: "Delete this book?"),
               isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } })) {
            Button(String(localized: "Delete Book File"), role: .destructive) {
                if let book = pendingDelete {
                    store.remove(book.id, deleteFiles: true)
                }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(localized: "The copy in your library will be removed. The original file is untouched."))
        }
        .sheet(isPresented: $showStats) {
            EbookReadingStatsView(onClose: { showStats = false })
        }
        .sheet(isPresented: $showFullTextSearch) {
            EbookLibrarySearchView(
                books: store.books,
                query: query,
                onOpen: { hit in
                    guard let book = store.book(id: hit.bookID) else { return }
                    showFullTextSearch = false
                    if let onOpenAt {
                        onOpenAt(book, hit.chapterIndex, query)
                    } else {
                        onOpen(book)
                    }
                },
                onClose: { showFullTextSearch = false })
        }
        .sheet(item: $renaming) { book in
            renameSheet(book)
        }
        .sheet(item: $collectionTarget) { book in
            collectionSheet(book)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Books"))
                    .font(.system(size: 19, weight: .semibold))
                Text(verbatim: "\(store.books.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let summary = statsSummary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button { showStats = true } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Reading Stats"))
                if importing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    importBooks()
                } label: {
                    Label(String(localized: "Import Books…"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Search books"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .frame(maxWidth: 360)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    showFullTextSearch = true
                } label: {
                    Label(String(localized: "Search inside all books"),
                          systemImage: "text.magnifyingglass")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
            }
            HStack(spacing: 6) {
                filterChip(String(localized: "All"),
                           active: !favoritesOnly && collectionFilter == nil) {
                    favoritesOnly = false
                    collectionFilter = nil
                }
                filterChip(String(localized: "Favorites"), active: favoritesOnly) {
                    favoritesOnly = true
                    collectionFilter = nil
                }
                Menu {
                    Button(String(localized: "All")) {
                        collectionFilter = nil
                        favoritesOnly = false
                    }
                    ForEach(store.collections, id: \.self) { name in
                        Button {
                            collectionFilter = name
                            favoritesOnly = false
                        } label: {
                            if collectionFilter == name {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    Label(collectionFilter ?? String(localized: "Collection"),
                          systemImage: "folder")
                        .font(.system(size: 10.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(collectionFilter == nil
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(appAccent))
                Spacer(minLength: 8)
                Menu {
                    ForEach(LibrarySort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Label(sort.label, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            if let error {
                ToolErrorText(text: error)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(store.books.isEmpty
                 ? String(localized: "Your library is empty")
                 : String(localized: "No matching books"))
                .font(.system(size: 14, weight: .medium))
            Text(String(localized: "Import EPUB, TXT, Markdown, HTML or CBZ files to start reading. MOBI/AZW3 need Calibre."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if store.books.isEmpty {
                Button(String(localized: "Import Books…")) { importBooks() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func filterChip(_ title: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(active
                                           ? appAccent.opacity(0.16)
                                           : Color.secondary.opacity(0.08)))
                .foregroundStyle(active
                                 ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private func renameSheet(_ book: Ebook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Rename Book"))
                .font(.system(size: 14, weight: .semibold))
            TextField(String(localized: "Title"), text: $renameTitle)
                .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Author"), text: $renameAuthor)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { renaming = nil }
                    .buttonStyle(.bordered)
                Button(String(localized: "Save")) {
                    store.rename(book.id, title: renameTitle, author: renameAuthor)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func collectionSheet(_ book: Ebook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "New Collection"))
                .font(.system(size: 14, weight: .semibold))
            TextField(String(localized: "Collection name"), text: $newCollectionName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(String(localized: "Remove from Collection"), role: .destructive) {
                    store.setCollection(book.id, nil)
                    collectionTarget = nil
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Cancel")) { collectionTarget = nil }
                    .buttonStyle(.bordered)
                Button(String(localized: "Save")) {
                    store.setCollection(book.id, newCollectionName)
                    collectionTarget = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func bookCard(_ book: Ebook) -> some View {
        Button {
            store.touch(book.id)
            onOpen(book)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                EbookCoverView(store: store, book: book)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4),
                                      lineWidth: 0.5))
                    .overlay(alignment: .topTrailing) {
                        if book.favorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(appAccent.opacity(0.9)))
                                .padding(8)
                        }
                    }
                Text(book.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(book.authorOrUnknown)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: book.progress)
                    .controlSize(.small)
                    .tint(appAccent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(book.favorite
                   ? String(localized: "Remove from Favorites")
                   : String(localized: "Add to Favorites")) {
                store.setFavorite(book.id, !book.favorite)
            }
            Menu(String(localized: "Collection")) {
                Button(String(localized: "None")) {
                    store.setCollection(book.id, nil)
                }
                ForEach(store.collections, id: \.self) { name in
                    Button {
                        store.setCollection(book.id, name)
                    } label: {
                        if book.collectionName == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button(String(localized: "New Collection…")) {
                    newCollectionName = book.collectionName ?? ""
                    collectionTarget = book
                }
            }
            Button(String(localized: "Rename…")) {
                renameTitle = book.title
                renameAuthor = book.author
                renaming = book
            }
            Divider()
            Button(String(localized: "Remove from Library"), role: .destructive) {
                store.remove(book.id, deleteFiles: false)
            }
            Button(String(localized: "Delete Book File"), role: .destructive) {
                pendingDelete = book
            }
        }
    }

    private func importBooks() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.epub, .plainText]
        for ext in ["cbz", "mobi", "azw3", "md", "markdown", "html", "htm", "xhtml"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        importing = true
        error = nil
        note = nil
        Task {
            var failures: [String] = []
            var imported = 0
            for url in urls {
                do {
                    _ = try await store.importBook(at: url)
                    imported += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importing = false
            if imported > 0 {
                note = String(localized: "Imported \(imported) books.")
            }
            if !failures.isEmpty {
                error = failures.joined(separator: "\n")
            }
        }
    }
}

/// 封面加载（无封面时用标题色块占位）。
private struct EbookCoverView: View {
    let store: EbookLibraryStore
    let book: Ebook
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [placeholderColor.opacity(0.85),
                                            placeholderColor.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(book.title.prefix(1)))
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .task(id: book.id) {
            guard let url = store.coverURL(for: book) else { return }
            image = NSImage(contentsOf: url)
        }
    }

    private var placeholderColor: Color {
        let hue = Double(abs(book.title.hashValue % 360)) / 360
        return Color(hue: hue, saturation: 0.35, brightness: 0.55)
    }
}
