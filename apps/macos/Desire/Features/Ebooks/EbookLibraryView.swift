import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 电子书书架（v0.8.34 批次一）：封面网格、搜索、导入、继续阅读。
struct EbookLibraryView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let onOpen: (Ebook) -> Void

    @ObservedObject private var store = EbookLibraryStore.shared
    @State private var query = ""
    @State private var importing = false
    @State private var error: String?
    @State private var note: String?
    @State private var pendingDelete: Ebook?

    private var filtered: [Ebook] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = needle.isEmpty ? store.books : store.books.filter {
            $0.title.lowercased().contains(needle)
                || $0.author.lowercased().contains(needle)
                || $0.fileName.lowercased().contains(needle)
        }
        return base.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
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
