import SwiftUI
import WebKit

struct SuspendedTabView: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Tab Suspended")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Click to reload — \(tab.displayTitle)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Reload") {
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
