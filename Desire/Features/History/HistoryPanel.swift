import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @State private var searchText = ""

    private var filtered: [HistoryEntry] {
        guard !searchText.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("浏览历史").font(.headline)
                Spacer()
                if !store.entries.isEmpty {
                    Button("清除全部", role: .destructive) { store.clearAll() }
                        .foregroundStyle(.secondary)
                }
                Button("关闭", action: onClose)
            }
            .padding()

            if !store.entries.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索历史记录…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if filtered.isEmpty {
                EmptyState(message: searchText.isEmpty ? "暂无浏览记录" : "未找到匹配记录")
            } else {
                List(filtered) { entry in
                    EntryRow(
                        title: entry.title,
                        subtitle: entry.url,
                        action: { onSelect(entry.url) }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.removeEntry(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .contextMenu {
                        Button("在新标签页中打开") { onSelect(entry.url) }
                        Button("复制链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url, forType: .string)
                        }
                        Divider()
                        Button("删除", role: .destructive) { store.removeEntry(id: entry.id) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 500)
    }
}
