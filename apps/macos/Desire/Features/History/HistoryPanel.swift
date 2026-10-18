import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var groupMode: GroupMode = .date
    /// 站点模式下折叠的组（v0.7.21：折叠聚合 + 站内相对时间）。
    @State private var collapsedDomains: Set<String> = []
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

    /// 站点分组（v0.7.21）：聚合口径抽到纯逻辑 HistoryGrouping（与桥
    /// `/history?grouped=1` 同源）；无 host 的条目归"其它"。
    private var siteGrouped: [(String, [HistoryEntry])] {
        HistoryGrouping.byDomain(filtered).map { group in
            (group.domain.isEmpty ? String(localized: "Other") : group.domain, group.entries)
        }
    }

    private func domainFromURL(_ urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    /// 站点组内的相对时间（"2 小时前"）。
    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
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
                            if groupMode != .site || !collapsedDomains.contains(sectionTitle) {
                            ForEach(entries) { entry in
                                EntryRow(
                                    title: entry.title,
                                    subtitle: entry.url,
                                    badgeText: entry.visitCount > 1 ? "×\(entry.visitCount)" : nil,
                                    trailingText: groupMode == .site ? relativeTime(entry.timestamp) : nil,
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
                            }
                        } header: {
                            HStack(spacing: 4) {
                                if groupMode == .site {
                                    Image(systemName: collapsedDomains.contains(sectionTitle)
                                          ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(sectionTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(entries.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard groupMode == .site else { return }
                                if collapsedDomains.contains(sectionTitle) {
                                    collapsedDomains.remove(sectionTitle)
                                } else {
                                    collapsedDomains.insert(sectionTitle)
                                }
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
