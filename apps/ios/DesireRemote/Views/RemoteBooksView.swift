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
        NavigationLink {
            RemoteBookDetailView(book: book)
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
                Image(systemName: "chevron.right")
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

/// 书详情（v0.8.64 批 4，B1 剩余）：进度/续读 + **问这本书**（预填 Agent）
/// + 最近高亮与笔记（桌面摘录库按 bookHash 过滤，只读）。
struct RemoteBookDetailView: View {
    @EnvironmentObject var client: RemoteClient
    let book: RemoteBookItem
    @State private var asked = false

    var body: some View {
        List {
            Section {
                Button {
                    client.openBook(id: book.id, chapter: book.chapterIndex)
                } label: {
                    Label(book.progress > 0 ? "在 Mac 上续读" : "在 Mac 上打开",
                          systemImage: "macwindow")
                }
                Button {
                    client.sendPrompt(
                        "请打开书《\(book.title)》并结合它当前的内容跟我聊聊——先告诉我它的主题与进度，再问我想深入哪部分。")
                    asked = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { asked = false }
                } label: {
                    Label(asked ? "已发送到 Agent" : "问这本书", systemImage: "questionmark.bubble")
                }
                .disabled(asked)
            } footer: {
                Text("「问这本书」把指令发到桌面 Agent（需 Mac 在线），Agent 会打开书并结合内容作答。")
            }

            Section("最近高亮与笔记") {
                if client.bookHighlights.isEmpty {
                    Text(book.progress > 0 ? "还没有高亮——读的时候划选文字即可收藏。" : "先读几页，划选的文字会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(client.bookHighlights) { highlight in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "highlighter")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                if let chapter = highlight.chapterTitle, !chapter.isEmpty {
                                    Text(chapter)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(Date(timeIntervalSince1970: highlight.createdAt), style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(highlight.content)
                                .font(.subheadline)
                                .lineLimit(4)
                            if let note = highlight.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(book.title.isEmpty ? "Untitled" : book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.requestBookHighlights(id: book.id) }
        .refreshable { client.requestBookHighlights(id: book.id) }
    }
}