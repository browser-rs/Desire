import SwiftUI
import WebKit

struct PrivacySettingsStoreSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlockerStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var privacyModeStore: PrivacyModeStore
    @ObservedObject var videoAdBlocker: VideoAdBlocker

    @State private var showClearConfirm = false
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearStorage = true
    @State private var clearHistory = true
    /// 清除范围（v0.8.80）：默认全部时间（与旧行为一致）。
    @State private var clearRange: PermissionMatrix.ClearRange = .allTime
    /// 历史自动保留天数（v0.8.81 批 2；0 = 永久）。
    @AppStorage("historyRetentionDays", store: AppPrefs.defaults) private var historyRetentionDays = 0

    var body: some View {
        SettingsContainer {
            // MARK: - History retention（v0.8.81 批 2）

            SettingsSection(
                title: String(localized: "History Retention"),
                subtitle: String(localized: "Automatically delete browsing history older than this period. 0 keeps everything."),
                icon: "clock.arrow.circlepath"
            ) {
                SettingsRow(
                    String(localized: "Keep history"),
                    subtitle: historyRetentionDays == 0
                        ? String(localized: "Forever")
                        : String(format: String(localized: "%lld days"), historyRetentionDays),
                    systemImage: "calendar"
                ) {
                    HStack(spacing: 8) {
                        Stepper(value: $historyRetentionDays, in: 0...3650, step: 30) {
                            EmptyView()
                        }
                        .labelsHidden()
                        if historyRetentionDays > 0 {
                            Button(String(localized: "Apply now")) {
                                historyStore.removeAll(before: Date().addingTimeInterval(
                                    -Double(historyRetentionDays) * 86_400))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            // MARK: - Web Content

            FilterListsSection()

            SettingsSection(
                title: "Web Content",
                subtitle: "Control how scripts, ads, and tracking behave on every site.",
                icon: "globe"
            ) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        "Enable JavaScript",
                        subtitle: "Required for most modern sites to work.",
                        systemImage: "curlybraces",
                        isOn: $settings.isJavaScriptEnabled
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Block Ads",
                        subtitle: "Block intrusive ad requests using the content blocker.",
                        systemImage: "rectangle.slash",
                        isOn: $contentBlocker.isBlockingEnabled
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Tracking Protection",
                        subtitle: "Block known trackers and analytics.",
                        systemImage: "eye.slash",
                        isOn: $contentBlocker.isTrackingEnabled
                    )
                    SettingsRowDivider()

                    // Cookie 弹窗自动处理（0.6.5）：分段三档，默认关。
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(.secondary)
                            Text("Cookie Banner Auto-Handling")
                            Spacer()
                            Picker("", selection: $settings.cookieBannerPolicy) {
                                Text("Off").tag("off")
                                Text("Reject All").tag("reject")
                                Text("Accept All").tag("accept")
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Text("Auto-click the reject/accept button on known consent banners (OneTrust, CookieBot and common banner patterns). Applied to new page loads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "HTTPS Upgrade",
                        subtitle: "Try to upgrade HTTP requests to HTTPS automatically.",
                        systemImage: "lock.shield",
                        isOn: $settings.httpsUpgradeEnabled
                    )
                    SettingsRowDivider()

                    // 严格 HTTPS-only（v0.8.80）：升级失败不再自动回退 HTTP。
                    SettingsToggleRow(
                        "HTTPS-Only Mode",
                        subtitle: "Never fall back to HTTP when the secure connection fails. The error page offers an explicit continue button.",
                        systemImage: "lock.trianglebadge.exclamationmark",
                        isOn: $settings.httpsOnlyMode
                    )
                    SettingsRowDivider()

                    // 站点通知权限的边界如实说明（WKWebView 无通知提示 API）。
                    SettingsRow(
                        "Website Notifications",
                        subtitle: "Web pages inside Desire cannot ask for notification permission; the system always denies it.",
                        systemImage: "bell.slash"
                    ) { EmptyView() }
                }
            }

            // MARK: - Cookies

            SettingsSection(
                title: "Cookies",
                subtitle: "Decide which cookies Desire accepts and view individual ones.",
                icon: "tray.full"
            ) {
                VStack(spacing: 0) {
                    SettingsPickerRow(
                        "Cookie Policy",
                        subtitle: "Control which cookies are accepted by the browser.",
                        systemImage: "tray.full",
                        selection: $privacyModeStore.cookieAcceptPolicy,
                        options: CookieAcceptPolicy.allCases,
                        label: { $0.displayName }
                    )
                    SettingsRowDivider()

                    SettingsRow(
                        "Manage Cookies",
                        subtitle: "View and delete individual cookies stored on this Mac.",
                        systemImage: "list.bullet.rectangle.portrait"
                    ) {
                        CookieManageButton()
                    }
                }
            }

            // MARK: - Suggestions

            SettingsSection(
                title: "Suggestions",
                subtitle: "What Desire sends to the search engine as you type.",
                icon: "text.magnifyingglass"
            ) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        "Show Search Suggestions",
                        subtitle: "Input is sent to the search engine for live suggestions.",
                        systemImage: "text.magnifyingglass",
                        isOn: $settings.showSearchSuggestions
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Link Preview",
                        subtitle: "Show the target URL at the bottom when hovering over a link.",
                        systemImage: "link",
                        isOn: $settings.showLinkPreview
                    )
                }
            }

            // MARK: - Website Data

            SiteDataSection()

            // MARK: - Permissions

            PrivacyDashboardSection(
                permissionStore: permissionStore,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker
            )

            // MARK: - Clear Data

            SettingsSection(
                title: "Clear Browsing Data",
                subtitle: "Pick what to remove. This action cannot be undone.",
                icon: "trash"
            ) {
                VStack(spacing: 0) {
                    // 时间范围（v0.8.80）：过去 1 小时 / 24 小时 / 7 天 / 全部。
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("Time Range")
                        Spacer()
                        Picker("", selection: $clearRange) {
                            Text("Past Hour").tag(PermissionMatrix.ClearRange.pastHour)
                            Text("Past 24 Hours").tag(PermissionMatrix.ClearRange.pastDay)
                            Text("Past 7 Days").tag(PermissionMatrix.ClearRange.pastWeek)
                            Text("All Time").tag(PermissionMatrix.ClearRange.allTime)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Cookies",
                        subtitle: "Sign-out state for every site.",
                        systemImage: "tray.full",
                        isOn: $clearCookies
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Cache",
                        subtitle: "Speed up repeat visits.",
                        systemImage: "bolt.slash",
                        isOn: $clearCache
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Local Storage",
                        subtitle: "LocalStorage, SessionStorage, IndexedDB, WebSQL.",
                        systemImage: "internaldrive",
                        isOn: $clearStorage
                    )
                    SettingsRowDivider()

                    SettingsToggleRow(
                        "Browsing History",
                        subtitle: "All entries in the history list.",
                        systemImage: "clock.arrow.circlepath",
                        isOn: $clearHistory
                    )
                    SettingsRowDivider()

                    HStack {
                        Spacer()
                        Button {
                            showClearConfirm = true
                        } label: {
                            Text("Clear Now")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(Color.red.opacity(0.14))
                                )
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(!(clearCookies || clearCache || clearStorage || clearHistory))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .alert("Clear Browsing Data", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearBrowsingData() }
        } message: {
            Text("Selected browsing data will be cleared. This action cannot be undone.")
        }
    }

    private func clearBrowsingData() {
        var types = Set<String>()
        if clearCookies { types.insert(WKWebsiteDataTypeCookies) }
        if clearCache {
            types.insert(WKWebsiteDataTypeDiskCache)
            types.insert(WKWebsiteDataTypeMemoryCache)
        }
        if clearStorage {
            types.insert(WKWebsiteDataTypeLocalStorage)
            types.insert(WKWebsiteDataTypeSessionStorage)
            types.insert(WKWebsiteDataTypeIndexedDBDatabases)
            types.insert(WKWebsiteDataTypeWebSQLDatabases)
        }
        let since = clearRange.since() ?? .distantPast
        if !types.isEmpty {
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: since) { }
        }
        if clearHistory {
            if let since = clearRange.since() {
                historyStore.removeAll(after: since)
            } else {
                historyStore.clearAll()
            }
        }
    }
}

// MARK: - Cookie manage button

/// Wraps the sheet-presenting button so it can live inside a `SettingsRow`.
private struct CookieManageButton: View {
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel = true
        } label: {
            HStack(spacing: 4) {
                Text("Manage")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(.tint.opacity(0.14))
            )
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPanel) {
            CookiePanel()
        }
    }
}

// MARK: - Site Data

private struct SiteDataSection: View {
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var isLoading = true

    var body: some View {
        SettingsSection(
            title: "Website Data",
            subtitle: "Local storage and databases stored by the sites you visit.",
            icon: "externaldrive"
        ) {
            VStack(spacing: 0) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.5)
                        Text("Loading…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if records.isEmpty {
                    Text("No stored website data")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(Array(records.enumerated()), id: \.element.displayName) { index, record in
                        siteRow(record)
                        if index < records.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadRecords)
    }

    private func siteRow(_ record: WKWebsiteDataRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(record.dataTypes.map { label(for: $0) }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // 按类型清除（v0.8.25）：只清 cookies 保留本地存储，或反之。
            Menu {
                Button(String(localized: "Delete All Data")) {
                    delete(record, types: nil)
                }
                Divider()
                ForEach(Array(record.dataTypes).sorted(), id: \.self) { type in
                    Button(String(localized: "Delete ") + label(for: type)) {
                        delete(record, types: [type])
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Choose what to delete"))
            Button {
                delete(record, types: nil)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.red.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    /// 按类型删除（nil = 全部），走 SiteDataManager 的统一口径。
    private func delete(_ record: WKWebsiteDataRecord, types: [String]?) {
        Task {
            _ = await SiteDataManager.remove(
                record.displayName,
                types: types?.map { SiteDataManager.shortName($0) })
            loadRecords()
        }
    }

    private func loadRecords() {
        isLoading = true
        let types: Set = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                          WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
            self.records = records.sorted { $0.displayName < $1.displayName }
            self.isLoading = false
        }
    }

    private func label(for type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: return "Cookie"
        case WKWebsiteDataTypeLocalStorage: return String(localized: "Local Storage")
        case WKWebsiteDataTypeSessionStorage: return String(localized: "Session Storage")
        case WKWebsiteDataTypeIndexedDBDatabases: return "IndexedDB"
        case WKWebsiteDataTypeWebSQLDatabases: return "WebSQL"
        default: return type
        }
    }
}

// MARK: - Privacy Dashboard entry

/// 设置页里的入口行：一行摘要 + 打开隐私与安全面板（矩阵/统计都在面板里）。
/// 此前的平铺权限列表按 host 去重展示有缺陷（多类型规则只显示一条），
/// v0.8.6 起由面板矩阵取代。
private struct PrivacyDashboardSection: View {
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var contentBlocker: ContentBlockerStore
    @ObservedObject var videoAdBlocker: VideoAdBlocker
    @State private var showDashboard = false

    private var summary: String {
        let hosts = Set(permissionStore.rules.map(\.host)).count
        if hosts == 0 { return String(localized: "No saved permission settings") }
        if hosts == 1 { return String(localized: "1 site with saved permissions") }
        return String(format: String(localized: "%lld sites with saved permissions"), hosts)
    }

    var body: some View {
        SettingsSection(
            title: "Website Permissions",
            subtitle: "Camera, microphone, location decisions per site.",
            icon: "checkmark.shield"
        ) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.tint.opacity(0.10)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy Dashboard")
                        .font(.system(size: 12, weight: .medium))
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showDashboard = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.tint.opacity(0.14)))
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
        }
        .sheet(isPresented: $showDashboard) {
            PrivacyDashboardView(
                permissions: permissionStore,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker
            )
        }
    }
}

// MARK: - Filter Lists

/// Community ad filter lists (EasyList China / EasyList) with automatic
/// weekly updates, backed by `FilterListStore`.
private struct FilterListsSection: View {
    @ObservedObject var store = FilterListStore.shared

    var body: some View {
        SettingsSection(
            title: "Filter Lists",
            subtitle: "Community-maintained ad filter lists with weekly auto-updates.",
            icon: "shield.lefthalf.filled"
        ) {
            VStack(spacing: 0) {
                ForEach(store.lists) { list in
                    SettingsToggleRow(
                        list.name,
                        subtitle: statusLine(for: list),
                        systemImage: "list.bullet.rectangle",
                        isOn: Binding(
                            get: { list.isEnabled },
                            set: { store.setEnabled($0, for: list.id) }
                        )
                    )
                    SettingsRowDivider()
                }

                HStack {
                    Button("立即更新全部") {
                        for list in store.lists where list.isEnabled {
                            store.refresh(id: list.id, force: true)
                        }
                    }
                    .disabled(!store.lists.contains(where: { $0.isEnabled && !$0.isUpdating }))
                    if store.lists.contains(where: { $0.isUpdating }) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("列表由 EasyList 社区维护，每 7 天自动更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private func statusLine(for list: FilterListStore.ListState) -> String {
        if list.isUpdating { return "正在更新…" }
        if let error = list.errorText { return "更新失败：\(error)" }
        guard let last = list.lastUpdated else { return list.subtitle + " · 尚未下载" }
        let days = Int(Date().timeIntervalSince(last) / 86400)
        let updated = days == 0 ? "今天" : "\(days) 天前"
        let count = list.ruleCount.map { "· \($0) 条规则" } ?? ""
        return "\(list.subtitle) · 上次更新：\(updated) \(count)"
    }
}
