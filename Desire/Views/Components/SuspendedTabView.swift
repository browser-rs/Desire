import SwiftUI
import WebKit

struct SuspendedTabView: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("此标签页已休眠")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("点击以重新加载 — \(tab.displayTitle)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("重新加载") {
                reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onTapGesture {
            reload()
        }
    }

    private func reload() {
        tab.isSuspended = false
        tab.lastAccessed = Date()
        if let url = tab.browser.webView.url {
            tab.browser.webView.load(URLRequest(url: url))
        } else if let url = URL(string: tab.urlString) {
            tab.browser.webView.load(URLRequest(url: url))
        }
    }
}
