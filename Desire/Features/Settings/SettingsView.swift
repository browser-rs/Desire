import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlocker
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
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
