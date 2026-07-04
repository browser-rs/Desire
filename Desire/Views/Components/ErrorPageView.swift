import SwiftUI
import WebKit

struct ErrorPageView: View {
    let message: String
    let tab: Tab

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Cannot Load Page")
                .font(.title2)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 400)

            Button("Reload") {
                tab.browser.lastError = nil
                if let url = URL(string: tab.urlString) {
                    tab.browser.webView.load(URLRequest(url: url))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
