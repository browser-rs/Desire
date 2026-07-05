import Foundation
import SwiftUI
import WebKit

/// Maps raw `URLError` codes to the human-friendly strings Desire shows in
/// the inline error page. We don't just print `error.localizedDescription`
/// because Apple's stock strings are sometimes too terse to be useful, and
/// because the user explicitly reported that the bare "TLS错误导致安全连接失败"
/// is unhelpful — they need to know *what* to try next.
enum BrowserErrorTranslator {
    /// Title for the error page (e.g. "Cannot Load Page").
    static func title(for error: Error) -> String {
        guard let urlError = error as? URLError else { return String(localized: "Cannot Load Page") }
        switch urlError.code {
        case .serverCertificateUntrusted,
             .secureConnectionFailed,
             .clientCertificateRequired:
            return String(localized: "Secure Connection Failed")
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return String(localized: "No Internet Connection")
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return String(localized: "Server Unreachable")
        case .cancelled:
            // `.cancelled` fires every time the user navigates away (back,
            // forward, address-bar load), so it's not really an error —
            // don't show a page for it.
            return ""
        default:
            return String(localized: "Cannot Load Page")
        }
    }

    /// Body text — explains what happened and what to try.
    static func message(for error: Error) -> String {
        let base = error.localizedDescription
        guard let urlError = error as? URLError else { return base }
        switch urlError.code {
        case .serverCertificateUntrusted:
            return String(localized: "The site's certificate is not trusted by macOS. This often means your system clock is wrong, or a corporate / security product is intercepting the connection. Check Date & Time in System Settings, then reload.")
        case .secureConnectionFailed:
            return String(localized: "macOS could not complete the TLS handshake. Common causes: incorrect system date/time, outdated root certificates (run Software Update), or a firewall/VPN rewriting TLS. Try reloading in a few seconds.")
        case .clientCertificateRequired,
             .clientCertificateRejected:
            return String(localized: "The site requires a client certificate. Open Settings → Privacy → Certificates to manage installed client certs.")
        case .notConnectedToInternet,
             .dataNotAllowed,
             .networkConnectionLost,
             .internationalRoamingOff:
            return String(localized: "Desire can't reach the network. Check that Wi-Fi or Ethernet is on, and that no app is in Airplane Mode.")
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return String(localized: "The server didn't respond. The site may be down, or a firewall is blocking the connection. Try reloading, or open the same URL in Safari to test.")
        default:
            return base
        }
    }

    /// SF Symbol to render next to the title.
    static func symbol(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "exclamationmark.triangle" }
        switch urlError.code {
        case .serverCertificateUntrusted,
             .secureConnectionFailed,
             .clientCertificateRequired:
            return "lock.trianglebadge.exclamationmark"
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return "wifi.slash"
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return "antenna.radiowaves.left.and.right.slash"
        default:
            return "exclamationmark.triangle"
        }
    }
}

struct ErrorPageView: View {
    let error: Error
    let tab: Tab

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: BrowserErrorTranslator.symbol(for: error))
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(BrowserErrorTranslator.title(for: error))
                .font(.title2)

            Text(BrowserErrorTranslator.message(for: error))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Reload") {
                    tab.browser.lastError = nil
                    if let url = URL(string: tab.urlString) {
                        tab.browser.webView.load(URLRequest(url: url))
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Open in Safari") {
                    if let url = URL(string: tab.urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
