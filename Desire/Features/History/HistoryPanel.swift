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

    private var grouped: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else { return [] }
        guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return [] }

        var today: [HistoryEntry] = []
        var yesterday: [HistoryEntry] = []
        var thisWeek: [HistoryEntry] = []
        var earlier: [HistoryEntry] = []

        for entry in filtered {
            if entry.timestamp >= todayStart {
                today.append(entry)
            } else if entry.timestamp >= yesterdayStart {
                yesterday.append(entry)
            } else if entry.timestamp >= weekStart {
                thisWeek.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var sections: [(String, [HistoryEntry])] = []
        if !today.isEmpty { sections.append(("今天", today)) }
        if !yesterday.isEmpty { sections.append(("昨天", yesterday)) }
        if !thisWeek.isEmpty { sections.append(("本周", thisWeek)) }
        if !earlier.isEmpty { sections.append(("更早", earlier)) }
        return sections
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
                List {
                    ForEach(grouped, id: \.0) { sectionTitle, entries in
                        Section {
                            ForEach(entries) { entry in
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
                        } header: {
                            Text(sectionTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 500)
    }
}

#Preview {
    HistoryPanel(store: HistoryStore(), onSelect: { _ in }, onClose: {})
        .frame(width: 420, height: 500)
}
