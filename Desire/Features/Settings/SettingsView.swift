import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlocker
    @ObservedObject var downloadStore: DownloadStore
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

                Button("清除浏览数据", role: .destructive) {
                    showClearConfirm = true
                }
            }
            .padding()
            .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 400, height: 320)
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
