import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlocker
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore
    var onDone: () -> Void
    @State private var showClearConfirm = false
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearStorage = true
    @State private var clearHistory = true

    var body: some View {
        TabView {
            Form {
                Picker("Default Search Engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }

                CustomEngineSection(settings: settings)

                TextField("Homepage URL", text: $settings.homePage)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download Location")
                        Text(downloadStore.downloadFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") {
                        downloadStore.chooseDownloadFolder()
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screenshot save location")
                        Text(settings.screenshotFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") {
                        settings.chooseScreenshotFolder()
                    }
                    Button("Reset") {
                        settings.resetScreenshotFolder()
                    }
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Toggle("Enable JavaScript", isOn: $settings.isJavaScriptEnabled)

                Toggle("Block Ads", isOn: $contentBlocker.isBlockingEnabled)

                Toggle("Tracking Protection", isOn: $contentBlocker.isTrackingEnabled)

                Toggle("HTTPS Upgrade", isOn: $settings.httpsUpgradeEnabled)
                    .help("Attempt to upgrade HTTP connections to HTTPS automatically")

                Divider()

                Toggle("Show Search Suggestions", isOn: $settings.showSearchSuggestions)
                    .help("Input will be sent to the search engine to get suggestions")

                Toggle("Link Preview", isOn: $settings.showLinkPreview)
                    .help("Show target URL at bottom when hovering over links")

                Divider()

                SiteDataSection()

                Divider()

                PermissionSection(store: permissionStore)

                Divider()

                ClearDataSection(
                    clearCookies: $clearCookies,
                    clearCache: $clearCache,
                    clearStorage: $clearStorage,
                    clearHistory: $clearHistory,
                    onClear: { showClearConfirm = true }
                )
            }
            .padding()
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            FormAutofillSettingsView(store: formAutofillStore)
                .tabItem { Label("Autofill", systemImage: "doc.text.fill") }

            KeyboardShortcutsView()
                .tabItem { Label("Keyboard Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 440, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", action: onDone)
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

private struct ClearDataSection: View {
    @Binding var clearCookies: Bool
    @Binding var clearCache: Bool
    @Binding var clearStorage: Bool
    @Binding var clearHistory: Bool
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clear Browsing Data")
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Cookies", isOn: $clearCookies)
                    Toggle("Cache", isOn: $clearCache)
                    Toggle("Local Storage", isOn: $clearStorage)
                    Toggle("Browsing History", isOn: $clearHistory)
                }
                .padding(4)
            }
            Button("Clear", role: .destructive) { onClear() }
                .disabled(!(clearCookies || clearCache || clearStorage || clearHistory))
        }
    }
}

private struct SiteDataSection: View {
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Website Data")
                .font(.headline)

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 20)
            } else if records.isEmpty {
                Text("No stored website data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
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
                .listStyle(.plain)
                .frame(height: 120)
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

private struct PermissionSection: View {
    @ObservedObject var store: PermissionStore
    @State private var showClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Website Permissions")
                    .font(.headline)
                Spacer()
                if !store.rules.isEmpty {
                    Button("Reset All", role: .destructive) { showClear = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if store.rules.isEmpty {
                Text("No saved permission settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(store.rules, id: \.host) { rule in
                        HStack {
                            Text(rule.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(rule.decision == .deny ? "Denied" : "Allowed")
                                .font(.caption)
                                .foregroundStyle(rule.decision == .deny ? .red : .green)
                            Button("Revoke") {
                                store.remove(host: rule.host)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: 100)
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

private struct CustomEngineSection: View {
    @ObservedObject var settings: Settings
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newSuggestionURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Custom Search Engines")
                    .font(.headline)
                Spacer()
                Button("Add") { showAdd = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }

            if settings.customEngines.isEmpty {
                Text("No custom search engines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(settings.customEngines) { engine in
                        HStack {
                            Text(engine.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Button("Delete") { settings.removeCustomEngine(engine.id) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: 80)
            }
        }
        .sheet(isPresented: $showAdd) {
            VStack(spacing: 16) {
                Text("Add Search Engine").font(.headline)
                TextField("Name (e.g. Wikipedia)", text: $newName)
                TextField("Search URL (e.g. https://en.wikipedia.org/wiki/Special:Search?search=)", text: $newURL)
                TextField("Suggestion URL (optional)", text: $newSuggestionURL)
                HStack {
                    Button("Cancel") { showAdd = false }
                    Button("Add") {
                        settings.addCustomEngine(name: newName, searchURL: newURL, suggestionURL: newSuggestionURL)
                        newName = ""; newURL = ""; newSuggestionURL = ""
                        showAdd = false
                    }
                    .disabled(newName.isEmpty || newURL.isEmpty)
                }
            }
            .padding()
            .frame(width: 420)
        }
    }
}

private struct KeyboardShortcutsView: View {
    private let shortcuts: [(String, LocalizedStringKey)] = [
        ("⌘T", "New Tab"),
        ("⌘⇧N", "New Incognito Tab"),
        ("⌘W", "Close Tab"),
        ("⌘⇧T", "Reopen Closed Tab"),
        ("⌘{", "Previous Tab"),
        ("⌘}", "Next Tab"),
        ("⌘1-9", "Switch to Tab 1-9"),
        ("⌘L", "Focus Address Bar"),
        ("⌘R", "Reload Page"),
        ("⌘F", "Find in Page"),
        ("⌘G", "Find Next"),
        ("⌘⇧G", "Find Previous"),
        ("Esc", "Exit Find"),
        ("⌘[", "Go Back"),
        ("⌘]", "Go Forward"),
        ("⌘=", "Zoom In"),
        ("⌘-", "Zoom Out"),
        ("⌘0", "Reset Zoom"),
        ("⌘⇧I", "Inspect Element"),
        ("⌘P", "Print"),
        ("⌘Y", "Browsing History"),
        ("⌘⇧A", "Search Tabs"),
        ("⌘⇧B", "Sidebar"),
        ("⌘⇧M", "Responsive Design Mode"),
    ]

    var body: some View {
        List(shortcuts, id: \.0) { shortcut in
            HStack {
                Text(shortcut.0)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcut.1)
            }
        }
        .padding()
    }
}
