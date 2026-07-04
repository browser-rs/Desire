import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlocker
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    var onDone: () -> Void
    @State private var showClearConfirm = false

    var body: some View {
        TabView {
            Form {
                Picker("默认搜索引擎", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }

                CustomEngineSection(settings: settings)

                TextField("主页 URL", text: $settings.homePage)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下载位置")
                        Text(downloadStore.downloadFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("更改…") {
                        downloadStore.chooseDownloadFolder()
                    }
                }
            }
            .padding()
            .tabItem { Label("常规", systemImage: "gearshape") }

            Form {
                Toggle("启用 JavaScript", isOn: $settings.isJavaScriptEnabled)

                Toggle("广告屏蔽", isOn: $contentBlocker.isBlockingEnabled)

                Divider()

                Toggle("显示搜索建议", isOn: $settings.showSearchSuggestions)
                    .help("开启后输入内容会发送给当前搜索引擎以获取建议")

                Divider()

                SiteDataSection()

                Divider()

                PermissionSection(store: permissionStore)

                Divider()

                Button("清除所有浏览数据", role: .destructive) {
                    showClearConfirm = true
                }
            }
            .padding()
            .tabItem { Label("隐私", systemImage: "hand.raised") }

            FormAutofillSettingsView(store: formAutofillStore)
                .tabItem { Label("自动填充", systemImage: "doc.text.fill") }
        }
        .frame(width: 440, height: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", action: onDone)
            }
        }
        .alert("清除浏览数据", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { clearBrowsingData() }
        } message: {
            Text("将清除缓存、Cookies 和本地存储数据。此操作不可撤销。")
        }
    }

    private func clearBrowsingData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { }
    }
}

private struct SiteDataSection: View {
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网站数据")
                .font(.headline)

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 20)
            } else if records.isEmpty {
                Text("没有存储的网站数据")
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
                            Button("删除") {
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
        case WKWebsiteDataTypeLocalStorage: return "本地存储"
        case WKWebsiteDataTypeSessionStorage: return "会话存储"
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
                Text("网站权限")
                    .font(.headline)
                Spacer()
                if !store.rules.isEmpty {
                    Button("重置全部", role: .destructive) { showClear = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if store.rules.isEmpty {
                Text("没有保存的权限设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(store.rules, id: \.host) { rule in
                        HStack {
                            Text(rule.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(rule.decision == .deny ? "已拒绝" : "已允许")
                                .font(.caption)
                                .foregroundStyle(rule.decision == .deny ? .red : .green)
                            Button("撤销") {
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
        .alert("重置所有权限", isPresented: $showClear) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { store.removeAll() }
        } message: {
            Text("这将清除所有网站保存的摄像头、麦克风和位置权限设置。")
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
                Text("自定义搜索引擎")
                    .font(.headline)
                Spacer()
                Button("添加") { showAdd = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }

            if settings.customEngines.isEmpty {
                Text("暂无自定义搜索引擎")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(settings.customEngines) { engine in
                        HStack {
                            Text(engine.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Button("删除") { settings.removeCustomEngine(engine.id) }
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
                Text("添加搜索引擎").font(.headline)
                TextField("名称（如：Wikipedia）", text: $newName)
                TextField("搜索 URL（如：https://en.wikipedia.org/wiki/Special:Search?search=）", text: $newURL)
                TextField("建议 URL（可选）", text: $newSuggestionURL)
                HStack {
                    Button("取消") { showAdd = false }
                    Button("添加") {
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
