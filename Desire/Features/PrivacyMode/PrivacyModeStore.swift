import Combine
import Foundation
import WebKit

@MainActor
class PrivacyModeStore: ObservableObject {
    @Published var state: PrivacyModeState {
        didSet {
            saveState()
        }
    }

    @Published var cookieAcceptPolicy: CookieAcceptPolicy {
        didSet {
            UserDefaults.standard.set(cookieAcceptPolicy.rawValue, forKey: "cookieAcceptPolicy")
            applyCookiePolicy()
        }
    }

    private let stateKey = "privacyModeState"
    private var registeredWebViews: [WeakWebViewBox] = []

    init() {
        // Load saved state
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let savedState = try? JSONDecoder().decode(PrivacyModeState.self, from: data) {
            state = savedState
        } else {
            state = PrivacyModeState()
        }

        // Load cookie policy
        if let policyRaw = UserDefaults.standard.string(forKey: "cookieAcceptPolicy"),
           let policy = CookieAcceptPolicy(rawValue: policyRaw) {
            cookieAcceptPolicy = policy
        } else {
            cookieAcceptPolicy = .onlyFromMainDocumentDomain
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    /// Register a WKWebView configuration to apply privacy settings
    func register(_ configuration: WKWebViewConfiguration) {
        applyPrivacySettings(to: configuration)
    }

    /// Apply privacy settings to a WKWebView configuration
    func applyPrivacySettings(to configuration: WKWebViewConfiguration) {
        // Apply cookie policy
        configuration.websiteDataStore.httpCookieStore.setCookiePolicy(cookiePolicyForWKWebView())

        // Apply tracking prevention
        if state.preventCrossSiteTracking {
            // This is handled by ContentBlocker's tracking rules
        }

        // Apply WebRTC settings
        if state.disableWebRTC {
            // Disable WebRTC by preventing peer connection
            let script = WKUserScript(
                source: """
                (function() {
                    if (window.RTCPeerConnection) {
                        window.RTCPeerConnection = undefined;
                    }
                    if (window.webkitRTCPeerConnection) {
                        window.webkitRTCPeerConnection = undefined;
                    }
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }
    }

    /// Convert CookieAcceptPolicy to WKHTTPCookieStore policy
    private func cookiePolicyForWKWebView() -> WKHTTPCookieStore.CookiePolicy {
        // Note: WKHTTPCookieStore.CookiePolicy only has .allow and .disallow
        // For third-party blocking, we need to use WKContentRuleList instead
        switch cookieAcceptPolicy {
        case .always:
            return .allow
        case .never:
            return .disallow
        case .onlyFromMainDocumentDomain:
            // WKHTTPCookieStore doesn't support this directly on macOS
            // We'll use .allow and rely on ContentBlocker's block-cookies rule
            return .allow
        }
    }

    /// Apply cookie policy to all registered web views
    private func applyCookiePolicy() {
        registeredWebViews.removeAll { $0.webView == nil }
        for box in registeredWebViews {
            guard let webView = box.webView else { continue }
            webView.configuration.websiteDataStore.httpCookieStore.setCookiePolicy(cookiePolicyForWKWebView())
        }
    }

    /// Create a non-persistent data store for privacy/incognito tabs
    static func createIncognitoDataStore() -> WKWebsiteDataStore {
        return WKWebsiteDataStore.nonPersistent()
    }

    /// Clear all privacy-sensitive data
    func clearPrivacyData() {
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases
        ]

        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            print("Privacy data cleared")
        }
    }

    /// Enable or disable privacy mode
    func togglePrivacyMode() {
        state.isEnabled.toggle()
    }
}

private final class WeakWebViewBox {
    weak var webView: WKWebView?
    init(webView: WKWebView) {
        self.webView = webView
    }
}