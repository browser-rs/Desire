import Combine
import SwiftUI
import WebKit

enum SearchEngine: String, CaseIterable {
    case google = "Google"
    case duckduckgo = "DuckDuckGo"
    case bing = "Bing"
    case baidu = "Baidu"

    var searchURL: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckduckgo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .baidu: "https://www.baidu.com/s?wd="
        }
    }
}

@MainActor
class Settings: ObservableObject {
    @Published var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    @Published var homePage: String {
        didSet { UserDefaults.standard.set(homePage, forKey: "homePage") }
    }
    @Published var isJavaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(isJavaScriptEnabled, forKey: "isJavaScriptEnabled") }
    }

    static let shared = Settings()

    init() {
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = UserDefaults.standard.string(forKey: "homePage") ?? "https://www.google.com"
        isJavaScriptEnabled = UserDefaults.standard.object(forKey: "isJavaScriptEnabled") as? Bool ?? true
    }

    var searchURLTemplate: String {
        searchEngine.searchURL
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
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
            }
            .padding()
            .tabItem { Label("常规", systemImage: "gearshape") }

            Form {
                Toggle("启用 JavaScript", isOn: $settings.isJavaScriptEnabled)

                Divider()

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
