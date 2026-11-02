import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 其他设备有、本机还没有文件的书（v0.8.37）：点导入选中同一个文件，
/// 按 SHA-256 匹配后接上进度/书签。
struct EbookRemoteBooksView: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var sync = EbookSyncStore.shared
    @ObservedObject private var library = EbookLibraryStore.shared
    let onClose: () -> Void

    @State private var importingHash: String?
    @State private var error: String?

    private var books: [EbookSyncBookPayload] {
        sync.orphanBooks.values.sorted {
            ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 12))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Books from other devices"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            Text(String(localized: "The book file itself is not synced. Choose the same file to continue."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            if books.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "No remote books"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(books, id: \.hash) { book in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title.isEmpty ? book.hash : book.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text(subtitle(book))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if importingHash == book.hash {
                                    ProgressView().controlSize(.small)
                                }
                                Button(String(localized: "Import File…")) {
                                    importFile(for: book)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(importingHash != nil)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 560, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func subtitle(_ book: EbookSyncBookPayload) -> String {
        var parts: [String] = []
        if !book.author.isEmpty { parts.append(book.author) }
        parts.append("\(Int((book.progress * 100).rounded()))%")
        if let chapter = book.lastOpenedAt {
            parts.append(chapter.formatted(date: .abbreviated, time: .omitted))
        }
        let bookmarks = sync.orphanBookmarks[book.hash.lowercased()]?.count ?? 0
        if bookmarks > 0 {
            parts.append(String(localized: "\(bookmarks) bookmark(s)"))
        }
        return parts.joined(separator: " · ")
    }

    private func importFile(for payload: EbookSyncBookPayload) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.epub, .plainText]
        for ext in ["cbz", "mobi", "azw3", "md", "markdown", "html", "htm", "xhtml", "fb2"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        importingHash = payload.hash
        Task {
            defer { importingHash = nil }
            do {
                let hash = try await Task.detached(priority: .userInitiated) {
                    try EbookImporter.hashFile(at: url)
                }.value
                guard hash.lowercased() == payload.hash.lowercased() else {
                    error = String(localized: "This file does not match this book.")
                    return
                }
                _ = try await library.importBook(at: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
