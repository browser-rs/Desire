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
        if !today.isEmpty { sections.append((String(localized: "Today"), today)) }
        if !yesterday.isEmpty { sections.append((String(localized: "Yesterday"), yesterday)) }
        if !thisWeek.isEmpty { sections.append((String(localized: "This Week"), thisWeek)) }
        if !earlier.isEmpty { sections.append((String(localized: "Earlier"), earlier)) }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !store.entries.isEmpty {
                    Button("Clear All", role: .destructive) { store.clearAll() }
                        .foregroundStyle(.secondary)
                }
                Button("Close", action: onClose)
            }
            .padding()

            if !store.entries.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search History…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if filtered.isEmpty {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Browsing History") : String(localized: "No Matching Records"))
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
                                    Button("Open in New Tab") { onSelect(entry.url) }
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.url, forType: .string)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.removeEntry(id: entry.id) }
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
