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
        Form {
            Toggle("Enable JavaScript", isOn: $settings.isJavaScriptEnabled)
            Toggle("Block Ads", isOn: $contentBlocker.isBlockingEnabled)
            Toggle("Tracking Protection", isOn: $contentBlocker.isTrackingEnabled)
            Toggle("HTTPS Upgrade", isOn: $settings.httpsUpgradeEnabled)
                .help("Attempt to upgrade HTTP connections to HTTPS automatically")

            Divider()

            Section("Cookie Policy") {
                Picker("Cookie Accept Policy", selection: $privacyModeStore.cookieAcceptPolicy) {
                    ForEach(CookieAcceptPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .help("Control which cookies are accepted by the browser")
            }

            Divider()

            Toggle("Show Search Suggestions", isOn: $settings.showSearchSuggestions)
                .help("Input will be sent to the search engine to get suggestions")
            Toggle("Link Preview", isOn: $settings.showLinkPreview)
                .help("Show target URL at bottom when hovering over links")

            Divider()

            SiteDataSection()
            CookieManagementSection()
            PermissionSection(store: permissionStore)
            ClearDataSection(
                clearCookies: $clearCookies,
                clearCache: $clearCache,
                clearStorage: $clearStorage,
                clearHistory: $clearHistory,
                onClear: { showClearConfirm = true }
            )
        }
        .padding()
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

private struct ClearDataSection: View {
    @Binding var clearCookies: Bool
    @Binding var clearCache: Bool
    @Binding var clearStorage: Bool
    @Binding var clearHistory: Bool
    let onClear: () -> Void

    var body: some View {
        Section("Clear Browsing Data") {
            Toggle("Cookies", isOn: $clearCookies)
            Toggle("Cache", isOn: $clearCache)
            Toggle("Local Storage", isOn: $clearStorage)
            Toggle("Browsing History", isOn: $clearHistory)
            Button("Clear", role: .destructive) { onClear() }
                .disabled(!(clearCookies || clearCache || clearStorage || clearHistory))
        }
    }
}

private struct SiteDataSection: View {
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var isLoading = true

    var body: some View {
        Section("Website Data") {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 20)
            } else if records.isEmpty {
                Text("No stored website data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records, id: \.displayName) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(record.dataTypes.map { label(for: $0) }.joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Delete") {
                            WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) {
                                loadRecords()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear(perform: loadRecords)
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

private struct CookieManagementSection: View {
    @State private var showPanel = false

    var body: some View {
        Section("Cookies") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Cookies")
                    Text("View and delete individual cookies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage…") { showPanel = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .sheet(isPresented: $showPanel) {
            CookiePanel()
        }
    }
}

private struct PermissionSection: View {
    @ObservedObject var store: PermissionStore
    @State private var showClear = false

    var body: some View {
        Section("Website Permissions") {
            if store.rules.isEmpty {
                Text("No saved permission settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.rules, id: \.host) { rule in
                    HStack {
                        Text(rule.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(rule.decision == .deny ? "Denied" : "Allowed")
                            .font(.caption)
                            .foregroundStyle(rule.decision == .deny ? .red : .green)
                        Button("Revoke") { store.remove(host: rule.host) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Reset All", role: .destructive) { showClear = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
        }
        .alert("Reset All Permissions", isPresented: $showClear) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.removeAll() }
        } message: {
            Text("This will clear all saved camera, microphone, and location permission settings for all websites.")
        }
    }
}
