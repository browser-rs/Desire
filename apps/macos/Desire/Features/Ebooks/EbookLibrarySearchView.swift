import SwiftUI

/// 全库搜索结果面板（v0.8.36）：按书分组，点结果跳到该书该章并高亮关键词。
struct EbookLibrarySearchView: View {
    @Environment(\.appAccent) private var appAccent
    let books: [Ebook]
    let query: String
    let onOpen: (EbookLibrarySearchHit) -> Void
    let onClose: () -> Void

    @State private var results: [EbookLibrarySearchHit] = []
    @State private var isSearching = true
    @State private var progress: Double = 0

    private var groups: [(bookID: UUID, title: String, hits: [EbookLibrarySearchHit])] {
        EbookLibrarySearchCore.grouped(results)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Search all books"))
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: "“\(query)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(String(localized: "Done")) { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            if isSearching {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                Text(String(localized: "Searching…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            if isSearching {
                Spacer()
            } else if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "No results in any book"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.bookID) { group in
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(appAccent)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group.hits) { hit in
                                Button {
                                    onOpen(hit)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.chapterTitle)
                                            .font(.system(size: 10.5, weight: .medium))
                                        Text(hit.snippet)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 600, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            isSearching = true
            results = []
            progress = 0
            results = await EbookLibrarySearchEngine.search(
                query: query, books: books) { done, total in
                    progress = total > 0 ? Double(done) / Double(total) : 0
                }
            isSearching = false
        }
    }
}
