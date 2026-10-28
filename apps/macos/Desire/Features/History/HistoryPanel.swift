import SwiftUI

struct HistoryPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var groupMode: GroupMode = .date
    /// 去重向导（v0.8.10）：非 nil = 展示。
    @State private var dedupeGroups: [HistoryDedupePlan.DuplicateGroup]?
    /// 按域名批量清理确认（v0.8.11）：非 nil = 弹确认。
    @State private var pendingDomainWipe: (domain: String, count: Int)?
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
        case date, site, timeline
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

    // MARK: - 时间线（v0.8.6）

    /// 按天分节的 24 格小时直方图（点击小时格 → 过滤该小时段的条目，
    /// 复用 siteFilter 上方那行提示位的空间：这里直接滚动到当天条目）。
    private var timelineSection: some View {
        let buckets = HistoryTimeline.build(from: filtered)
        return VStack(spacing: 14) {
            if buckets.isEmpty {
                Text("No visits to chart")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ForEach(buckets, id: \.dayKey) { bucket in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(Self.timelineDayTitle(bucket.date))
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(bucket.total)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let peak = bucket.peakHour, bucket.total > 0 {
                                Text(String(format: String(localized: "peak %02d:00"), peak))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        hourBars(bucket)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 24 根小时柱（高度按全天峰值归一）。hover 显示"HH:00 · N 次"。
    private func hourBars(_ bucket: HistoryTimeline.DayBucket) -> some View {
        let peak = max(1, bucket.hourly.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                let count = bucket.hourly[hour]
                RoundedRectangle(cornerRadius: 2)
                    .fill(count == 0 ? Color.secondary.opacity(0.15) : appAccent.opacity(0.65))
                    .frame(height: 4 + CGFloat(count) / CGFloat(peak) * 26)
                    .frame(maxHeight: 30, alignment: .bottom)
                    .help(String(format: String(localized: "%02d:00 — %d visit(s)"), hour, count))
            }
        }
        .frame(height: 32)
    }

    private static func timelineDayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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
                    Button("Dedupe…") {
                        dedupeGroups = HistoryDedupePlan.duplicateGroups(store.entries)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                if !store.entries.isEmpty {
                    Menu {
                        Button("JSON") { store.exportJSON() }
                        Button("CSV") { store.exportCSV() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                Menu {
                    Button("JSON / CSV…") { importLight() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
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
                        Image(systemName: "chart.bar").tag(GroupMode.timeline)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)

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
                Group {
                    if groupMode == .timeline {
                        timelineSection
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
                                    // 按域名批量清理（v0.8.11）：任意分组模式都可用了
                                    //（此前只在"站点"分组里出现，用户在日期模式下找不到）；
                                    // 确认弹窗带估删条数。
                                    if let domain = domainFromURL(entry.url) {
                                        let count = store.entries.filter {
                                            domainFromURL($0.url) == domain
                                        }.count
                                        Button("Delete All from \"\(domain)\" (\(count))", role: .destructive) {
                                            pendingDomainWipe = (domain, count)
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
            }
        }
        .sheet(item: Binding(
            get: { dedupeGroups.map { DedupeBox(groups: $0) } },
            set: { dedupeGroups = $0?.groups })) { box in
            HistoryDedupeSheet(groups: box.groups) { completedKeys in
                dedupeGroups = nil
                _ = completedKeys
            }
        }
        .confirmationDialog(
            "Delete All from \"\(pendingDomainWipe?.domain ?? "")\"?",
            isPresented: Binding(
                get: { pendingDomainWipe != nil },
                set: { if !$0 { pendingDomainWipe = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete \(pendingDomainWipe?.count ?? 0) entrie(s)"), role: .destructive) {
                if let domain = pendingDomainWipe?.domain {
                    store.removeAll(from: domain)
                }
                pendingDomainWipe = nil
            }
            Button("Cancel", role: .cancel) { pendingDomainWipe = nil }
        } message: {
            Text("All history entries for this domain will be removed. This cannot be undone.")
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

    @State private var importNote: String?

    private func importLight() {
        guard let result = store.importLightFormat() else { return }
        importNote = String(localized: "Imported \(result.added) new, merged \(result.skipped)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importNote = nil }
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


// MARK: - 去重向导（v0.8.10）

/// sheet(item:) 载荷（DuplicateGroup 数组本身不 Identifiable）。
private struct DedupeBox: Identifiable {
    let groups: [HistoryDedupePlan.DuplicateGroup]
    var id: String { "\(groups.count)-\(groups.first?.key ?? "")" }
}

/// 历史去重向导：列出语义重复组（同规范 URL），每组一键"合并"——保留
/// 最新行、次数相加、标题取最长。全合并按钮收尾。
private struct HistoryDedupeSheet: View {
    let groups: [HistoryDedupePlan.DuplicateGroup]
    /// 完成的组 key（面板据此清理并关 sheet）。
    let onDone: ([String]) -> Void
    @ObservedObject private var store: HistoryStore
    @State private var completed: Set<String> = []
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss

    init(groups: [HistoryDedupePlan.DuplicateGroup], onDone: @escaping ([String]) -> Void) {
        self.groups = groups
        self.onDone = onDone
        _store = ObservedObject(wrappedValue: HistoryStore())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(appAccent)
                Text("Merge Duplicate History")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Merge All")) {
                    mergeAll()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(completed.count == groups.count)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups.filter { !completed.contains($0.key) }, id: \.key) { group in
                        groupCard(group)
                    }
                    if completed.count == groups.count {
                        Text(String(localized: "All duplicates merged"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: 480)
    }

    private func groupCard(_ group: HistoryDedupePlan.DuplicateGroup) -> some View {
        let entries = store.entries
        let plan = HistoryDedupePlan.mergePlan(for: group, entries: entries)
        return VStack(alignment: .leading, spacing: 4) {
            Text(group.key)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
            ForEach(group.entryIDs.prefix(5), id: \.uuidString) { id in
                if let e = entries.first(where: { $0.id == id }) {
                    HStack(spacing: 6) {
                        Text(e.title.isEmpty ? e.url : e.title)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Spacer()
                        Text("×\(e.visitCount)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let plan {
                Button(String(localized: "Merge (keep newest, ×\(plan.mergedVisitCount))")) {
                    store.applyDedupe(plan: plan, dropIDs: plan.dropIDs)
                    completed.insert(group.key)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }

    private func mergeAll() {
        for group in groups where !completed.contains(group.key) {
            if let plan = HistoryDedupePlan.mergePlan(for: group, entries: store.entries) {
                store.applyDedupe(plan: plan, dropIDs: plan.dropIDs)
                completed.insert(group.key)
            }
        }
    }
}
