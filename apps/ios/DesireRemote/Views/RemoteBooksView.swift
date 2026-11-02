import SwiftUI

/// 书架（v0.8.38 批二）：Mac 书库的手机视图——按最近阅读排序，
/// 点一本就在 Mac 上从续读章节打开。
struct RemoteBooksView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var searchText = ""

    private var filtered: [RemoteBookItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return client.books }
        return client.books.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.author.localizedCaseInsensitiveContains(q)
                || ($0.collection?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var favorites: [RemoteBookItem] {
        filtered.filter(\.favorite)
    }

    private var others: [RemoteBookItem] {
        filtered.filter { !$0.favorite }
    }

    var body: some View {
        List {
            if client.books.isEmpty {
                DesireEmptyState(
                    icon: "books.vertical",
                    title: "Mac 书库还是空的",
                    message: "在 Mac 上把 EPUB / TXT / Markdown / CBZ 导入书架后，这里就能看到进度并一键续读。")
                    .listRowBackground(Color.clear)
            } else if filtered.isEmpty {
                Text("没有匹配 \(searchText) 的书")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                if !favorites.isEmpty {
                    Section {
                        ForEach(favorites) { book in
                            row(book)
                        }
                    } header: {
                        DesireSectionHeader(title: "收藏")
                    }
                }
                Section {
                    ForEach(others) { book in
                        row(book)
                    }
                } header: {
                    DesireSectionHeader(
                        title: favorites.isEmpty ? "全部书籍" : "其他书籍",
                        subtitle: "点一本在 Mac 上从上次位置继续阅读")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("书架")
        .searchable(text: $searchText, prompt: "按书名、作者或分组过滤")
        .onAppear { client.requestBooks() }
        .refreshable { client.requestBooks() }
    }

    private func row(_ book: RemoteBookItem) -> some View {
        Button {
            client.openBook(id: book.id, chapter: book.chapterIndex)
        } label: {
            HStack(spacing: 12) {
                DesireIconBadge(icon: "book.closed", size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title.isEmpty ? "Untitled" : book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !book.author.isEmpty {
                            Text(book.author)
                                .lineLimit(1)
                        }
                        Text(book.format)
                        if let collection = book.collection, !collection.isEmpty {
                            Text(collection)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    ProgressView(value: min(max(book.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(book.progress >= 0.999 ? .green : .accentColor)
                    HStack(spacing: 6) {
                        Text("\(Int((book.progress * 100).rounded()))%")
                        Text("第 \(min(book.chapterIndex + 1, max(book.chapterCount, 1))) / \(max(book.chapterCount, 1)) 章")
                        if let last = book.lastOpenedAt {
                            Text(Date(timeIntervalSince1970: last), style: .relative)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                client.openBook(id: book.id, chapter: 0)
            } label: {
                Label("从头读", systemImage: "text.book.closed")
            }
            .tint(.orange)
        }
    }
}
