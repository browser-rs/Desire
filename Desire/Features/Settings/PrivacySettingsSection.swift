import SwiftUI
import WebKit

struct PrivacySettingsStoreSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlockerStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var privacyModeStore: PrivacyModeStore

    @State private var showClearConfirm = false
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearStorage = true
    @State private var clearHistory = true

    var body: some View {
        SettingsContainer {
            // MARK: - Web Content

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

                    SettingsToggleRow(
                        "HTTPS Upgrade",
                        subtitle: "Try to upgrade HTTP requests to HTTPS automatically.",
                        systemImage: "lock.shield",
                        isOn: $settings.httpsUpgradeEnabled
                    )
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

            PermissionSection(store: permissionStore)

            // MARK: - Clear Data

            SettingsSection(
                title: "Clear Browsing Data",
                subtitle: "Pick what to remove. This action cannot be undone.",
                icon: "trash"
            ) {
                VStack(spacing: 0) {
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
        if !types.isEmpty {
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { }
        }
        if clearHistory {
            historyStore.clearAll()
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
                Capsule().fill(Color.accentColor.opacity(0.14))
            )
            .foregroundStyle(Color.accentColor)
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
            Button {
                WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) {
                    loadRecords()
                }
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

// MARK: - Permissions

private struct PermissionSection: View {
    @ObservedObject var store: PermissionStore
    @State private var showClear = false

    var body: some View {
        SettingsSection(
            title: "Website Permissions",
            subtitle: "Camera, microphone, location and notification grants per site.",
            icon: "checkmark.shield"
        ) {
            VStack(spacing: 0) {
                if store.rules.isEmpty {
                    Text("No saved permission settings")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    ForEach(Array(store.rules.enumerated()), id: \.element.host) { index, rule in
                        ruleRow(rule)
                        if index < store.rules.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                    SettingsRowDivider()
                    HStack {
                        Spacer()
                        Button {
                            showClear = true
                        } label: {
                            Text("Reset All")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .alert("Reset All Permissions", isPresented: $showClear) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.removeAll() }
        } message: {
            Text("This will clear all saved camera, microphone, and location permission settings for all websites.")
        }
    }

    private func ruleRow(_ rule: PermissionRule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: rule.decision == .deny ? "xmark.shield" : "checkmark.shield")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(rule.decision == .deny ? .red : .green)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill((rule.decision == .deny ? Color.red : .green).opacity(0.10))
                )

            Text(rule.host)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            StatusPill(
                text: rule.decision == .deny ? "Denied" : "Allowed",
                kind: rule.decision == .deny ? .error : .success
            )
            Button {
                store.remove(host: rule.host)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Revoke")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}
