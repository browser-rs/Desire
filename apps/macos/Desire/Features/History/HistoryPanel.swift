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
    /// 批量删除（v0.7.28）：选择模式 + 选中集合。
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    /// 只看某站（v0.7.28）：nil = 全部。
    @State private var siteFilter: String?
    /// 云归档搜索（v0.7.28）：端到端加密的服务端历史只能在客户端解密过滤。
    @State private var archiveHits: [HistoryArchiveSearch.Hit] = []
    @State private var archiveLoading = false
    @State private var archiveError: String?
    /// 正文索引（v0.8.0）：开启后按 query 本地搜已访问页面正文。
    @ObservedObject private var contentIndex = HistoryContentStore.shared
    @State private var contentHits: [HistoryContentHit] = []
    @State private var contentSearchTask: Task<Void, Never>?

    enum GroupMode: String, CaseIterable {
        case date, site
    }

    private var filtered: [HistoryEntry] {
        var result = store.entries
        if let siteFilter {
            result = result.filter { domainFromURL($0.url) == siteFilter }
        }
        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func deleteSelected() {
        for id in selectedIDs { store.removeEntry(id: id) }
        selectedIDs.removeAll()
        isSelecting = false
    }

    /// 云归档检索（v0.7.28）：登录态下按需拉取并本地解密，不进本地历史库。
    private func searchArchive() {
        guard let sync = AppState.live?.syncStore else {
            archiveError = String(localized: "Cloud sync is not available.")
            return
        }
        guard case .signedIn = sync.authState else {
            archiveError = String(localized: "Sign in to sync to search the archive.")
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        archiveLoading = true
        archiveError = nil
        Task { @MainActor in
            do {
                archiveHits = try await sync.searchArchivedHistory(query: query, limit: 50)
            } catch {
                archiveHits = []
                archiveError = error.localizedDescription
            }
            archiveLoading = false
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
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
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

                    Button { searchArchive() } label: {
                        if archiveLoading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "cloud")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || archiveLoading)
                    .help("Search the encrypted history archive")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if let siteFilter {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 10))
                    Text(siteFilter)
                        .font(.caption)
                    Button("Clear") { self.siteFilter = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            if let archiveError {
                Text(archiveError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if filtered.isEmpty && archiveHits.isEmpty && contentHits.isEmpty && !archiveLoading {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Browsing History") : String(localized: "No Matching Records"))
            } else {
                List {
                    if !contentHits.isEmpty {
                        Section(String(localized: "Found in page text")) {
                            ForEach(contentHits, id: \.record.url) { hit in
                                Button {
                                    onSelect(hit.record.url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.record.title)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(hit.record.url)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text(hit.snippet)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if archiveLoading || !archiveHits.isEmpty {
                        Section(String(localized: "Cloud archive")) {
                            if archiveLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Searching archive…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(Array(archiveHits.enumerated()), id: \.offset) { _, hit in
                                    EntryRow(title: hit.title, subtitle: hit.url,
                                             badgeText: hit.visitCount > 1 ? "×\(hit.visitCount)" : nil,
                                             trailingText: relativeTime(hit.timestamp),
                                             action: { onSelect(hit.url) })
                                }
                            }
                        }
                    }
                    let sections = groupMode == .date ? dateGrouped : siteGrouped
                    ForEach(sections, id: \.0) { sectionTitle, entries in
                        Section {
                            if groupMode != .site || !collapsedDomains.contains(sectionTitle) {
                            ForEach(entries) { entry in
                                HStack(spacing: 8) {
                                    if isSelecting {
                                        Image(systemName: selectedIDs.contains(entry.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(selectedIDs.contains(entry.id)
                                                             ? AnyShapeStyle(.tint)
                                                             : AnyShapeStyle(.secondary))
                                    }
                                    EntryRow(
                                        title: entry.title,
                                        subtitle: entry.url,
                                        badgeText: entry.visitCount > 1 ? "×\(entry.visitCount)" : nil,
                                        trailingText: groupMode == .site ? relativeTime(entry.timestamp) : nil,
                                        action: {
                                            if isSelecting {
                                                if selectedIDs.contains(entry.id) {
                                                    selectedIDs.remove(entry.id)
                                                } else {
                                                    selectedIDs.insert(entry.id)
                                                }
                                            } else {
                                                onSelect(entry.url)
                                            }
                                        }
                                    )
                                }
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
                                if groupMode == .site {
                                    Button {
                                        siteFilter = sectionTitle
                                    } label: {
                                        Image(systemName: "line.3.horizontal.decrease.circle")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Only this site")
                                }
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
        .onChange(of: searchText) { _, _ in
            // 查询变了，旧的归档结果立即作废（避免看到上一词的命中）。
            archiveHits = []
            archiveError = nil
            contentSearchTask?.cancel()
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contentIndex.isEnabled, !query.isEmpty else {
                contentHits = []
                return
            }
            contentSearchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                contentHits = contentIndex.search(query: query, limit: 20)
            }
        }
        .onDisappear { contentSearchTask?.cancel() }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedIDs.isEmpty {
                HStack(spacing: 10) {
                    Text(String(localized: "Selected") + " \(selectedIDs.count)")
                        .font(.caption)
                    Spacer()
                    Button(String(localized: "Delete"), role: .destructive) {
                        deleteSelected()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
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
