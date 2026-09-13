import Combine
import Foundation
import os
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

    /// DiskStore key for the state blob. Also reused as the legacy
    /// UserDefaults key for the one-time migration.
    private let stateKey = "privacyModeState"
    private var registeredWebViews: [WeakWebViewBox] = []

    init() {
        // Load saved state (DiskStore, with one-time legacy migration).
        if let savedState = DiskStore.load(PrivacyModeState.self, key: stateKey) {
            state = savedState
        } else if let data = UserDefaults.standard.data(forKey: stateKey),
                  let savedState = try? JSONDecoder().decode(PrivacyModeState.self, from: data) {
            state = savedState
            DiskStore.save(savedState, key: stateKey)
            UserDefaults.standard.removeObject(forKey: stateKey)
        } else {
            state = PrivacyModeState()
        }

        // Load cookie policy (scalar — stays on UserDefaults).
        if let policyRaw = UserDefaults.standard.string(forKey: "cookieAcceptPolicy"),
           let policy = CookieAcceptPolicy(rawValue: policyRaw) {
            cookieAcceptPolicy = policy
        } else {
            cookieAcceptPolicy = .onlyFromMainDocumentDomain
        }
    }

    private func saveState() {
        DiskStore.save(state, key: stateKey)
    }

    /// Register a WKWebView configuration to apply privacy settings
    func register(_ configuration: WKWebViewConfiguration) {
        applyPrivacySettingsStore(to: configuration)
    }

    /// Apply privacy settings to a WKWebView configuration
    func applyPrivacySettingsStore(to configuration: WKWebViewConfiguration) {
        // Apply cookie policy
        configuration.websiteDataStore.httpCookieStore.setCookiePolicy(cookiePolicyForWKWebView())

        // Apply tracking prevention
        if state.preventCrossSiteTracking {
            // This is handled by ContentBlockerStore's tracking rules
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
            // We'll use .allow and rely on ContentBlockerStore's block-cookies rule
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
            Log.privacy.info("privacy data cleared")
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