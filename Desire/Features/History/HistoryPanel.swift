import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var groupMode: GroupMode = .date
    @State private var showClearOptions = false

    enum GroupMode: String, CaseIterable {
        case date, site
    }

    private var filtered: [HistoryEntry] {
        guard !searchText.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var dateGrouped: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else { return [] }
        guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return [] }
        guard let monthStart = cal.date(byAdding: .month, value: -1, to: now) else { return [] }

        var today: [HistoryEntry] = []
        var yesterday: [HistoryEntry] = []
        var thisWeek: [HistoryEntry] = []
        var thisMonth: [HistoryEntry] = []
        var earlier: [HistoryEntry] = []

        for entry in filtered {
            if entry.timestamp >= todayStart {
                today.append(entry)
            } else if entry.timestamp >= yesterdayStart {
                yesterday.append(entry)
            } else if entry.timestamp >= weekStart {
                thisWeek.append(entry)
            } else if entry.timestamp >= monthStart {
                thisMonth.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var sections: [(String, [HistoryEntry])] = []
        if !today.isEmpty { sections.append((String(localized: "Today"), today)) }
        if !yesterday.isEmpty { sections.append((String(localized: "Yesterday"), yesterday)) }
        if !thisWeek.isEmpty { sections.append((String(localized: "This Week"), thisWeek)) }
        if !thisMonth.isEmpty { sections.append((String(localized: "This Month"), thisMonth)) }
        if !earlier.isEmpty { sections.append((String(localized: "Earlier"), earlier)) }
        return sections
    }

    private var siteGrouped: [(String, [HistoryEntry])] {
        var groups: [String: [HistoryEntry]] = [:]
        for entry in filtered {
            let domain = domainFromURL(entry.url) ?? String(localized: "Other")
            groups[domain, default: []].append(entry)
        }
        return groups.sorted { $0.key < $1.key }
    }

    private func domainFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !store.entries.isEmpty {
                    Menu {
                        Button("Clear Today") {
                            clearHistory(.today)
                        }
                        Button("Clear Yesterday") {
                            clearHistory(.yesterday)
                        }
                        Button("Clear This Week") {
                            clearHistory(.thisWeek)
                        }
                        Button("Clear This Month") {
                            clearHistory(.thisMonth)
                        }
                        Divider()
                        Button("Clear All", role: .destructive) {
                            store.clearAll()
                        }
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                Button("Close", action: onClose)
            }
            .padding()

            if !store.entries.isEmpty {
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search History…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Picker("Group by", selection: $groupMode) {
                        Image(systemName: "calendar").tag(GroupMode.date)
                        Image(systemName: "globe").tag(GroupMode.site)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 70)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if filtered.isEmpty {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Browsing History") : String(localized: "No Matching Records"))
            } else {
                List {
                    let sections = groupMode == .date ? dateGrouped : siteGrouped
                    ForEach(sections, id: \.0) { sectionTitle, entries in
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
                                    if groupMode == .site, let domain = domainFromURL(entry.url) {
                                        Button("Delete All from \"\(domain)\"", role: .destructive) {
                                            store.removeAll(from: domain)
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(sectionTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(entries.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 500)
    }

    private enum ClearRange {
        case today, yesterday, thisWeek, thisMonth
    }

    private func clearHistory(_ range: ClearRange) {
        let cal = Calendar.current
        let now = Date()
        let threshold: Date

        switch range {
        case .today:
            threshold = cal.startOfDay(for: now)
        case .yesterday:
            threshold = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now) ?? now)
        case .thisWeek:
            threshold = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        case .thisMonth:
            threshold = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        }

        store.removeAll(before: threshold)
    }
}
