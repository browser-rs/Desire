import Combine
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserState: ObservableObject {
    let webView: BrowserWKWebView
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle: String = "Desire"
    @Published var isSecure: Bool = false
    @Published var lastError: Error?
    @Published var pageZoom: Double = 1.0
    @Published var serverTrust: SecTrust?
    @Published var isPlayingAudio: Bool = false
    @Published var isMuted: Bool = false
    @Published var isReadingMode = false
    @Published var readerTitle = ""
    @Published var readerContent = ""
    @Published var hoveredLinkURL: String?
    @Published var isPickingElement = false
    let videoAdBlocker: VideoAdBlocker?

    init(incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil, videoAdBlocker: VideoAdBlocker? = nil) {
        self.videoAdBlocker = videoAdBlocker
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = javaScriptEnabled
        config.defaultWebpagePreferences = webpagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if incognito {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        // Use a full, real-Safari User-Agent.
        //
        // `applicationNameForUserAgent` only replaces the trailing app token
        // (e.g. "Safari/605.1.15"), so a value of "Version/18.6 Safari/605.1.15"
        // produces:
        //   Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15
        //   (KHTML, like Gecko)   <-- missing Version/ and Safari/ tokens
        // Cloudflare and other WAFs treat this as a bot, which is why
        // "由 Cloudflare 提供的性能和安全服务" verification challenges fire on
        // most sites. Setting `customUserAgent` to the full macOS 26.5
        // Safari string makes the request indistinguishable from real Safari.
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Explicitly enable HTML5 Fullscreen API for video sites (YouTube, etc.).
        // Defaults to true, but being explicit avoids edge cases where the
        // fullscreen transition silently no-ops inside SwiftUI-hosted WKWebView.
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15 Desire/0.1"
        contentBlocker?.apply(to: config)
        if let videoAdBlocker, videoAdBlocker.isEnabled {
            config.userContentController.addUserScript(videoAdBlocker.documentStartScript())
            config.userContentController.addUserScript(videoAdBlocker.documentEndScript())
        }

        let audioJS = """
        (function() {
            function checkAudio() {
            var playing = false;
            document.querySelectorAll('audio, video').forEach(function(el) {
                if (!el.paused && el.volume > 0) {
                        playing = true;
                    }
                });
                window.webkit.messageHandlers.audioState.postMessage(playing);
            }
            document.addEventListener('play', checkAudio, true);
            document.addEventListener('pause', checkAudio, true);
            document.addEventListener('volumechange', checkAudio, true);
            new MutationObserver(function() {
                if (document.querySelectorAll('audio, video').length) checkAudio();
            }).observe(document.body, { childList: true, subtree: true });
            setTimeout(checkAudio, 500);
        })();
        """
        let audioScript = WKUserScript(source: audioJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(audioScript)

        let passwordJS = """
        (function() {
            function detectLoginForm() {
                var pwd = document.querySelector('input[type=password]');
                if (!pwd) return;
                var form = pwd.closest('form');
                if (!form) return;
                var username = form.querySelector('input[type=text], input[type=email], input[name*=user], input[name*=email], input[name*=login]');
                if (!username) {
                    username = form.querySelector('input:not([type=password]):not([type=hidden])');
                }
                if (username) {
                    window.webkit.messageHandlers.passwordDetect.postMessage({
                        username: username.name || username.id || 'username'
                    });
                }
            }
            document.addEventListener('DOMContentLoaded', detectLoginForm);
            setTimeout(detectLoginForm, 1000);
        })();
        """
        let passwordScript = WKUserScript(source: passwordJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(passwordScript)

        let readerJS = """
        (function() {
            window._desireReader = function() {
                function score(el) {
                    var score = 0;
                    if (!el || !el.tagName) return 0;
                    var id = (el.id || '').toLowerCase();
                    var cls = (el.className || '').toLowerCase();
                    if (/article|post|content|main|story|entry/.test(id) || /article|post|content|main|story|entry/.test(cls)) score += 10;
                    if (/comment|sidebar|footer|header|nav|menu/.test(id) || /comment|sidebar|footer|header|nav|menu/.test(cls)) score -= 10;
                    var text = el.innerText || '';
                    var links = el.querySelectorAll('a').length;
                    var textLen = text.replace(/\\\\s+/g, ' ').length;
                    if (textLen > 100) score += Math.min(5, Math.floor(textLen / 500));
                    if (links > 0) score -= Math.min(3, Math.floor(links / 50));
                    return score;
                }
                var candidates = [];
                var els = document.querySelectorAll('article, [role=main], main, .post, .article, .content, #content, #article');
                if (els.length === 0) els = document.querySelectorAll('p');
                if (els.length > 0) {
                    for (var i = 0; i < els.length; i++) {
                        var el = els[i];
                        var s = score(el);
                        if (s > 0) candidates.push({el: el, score: s});
                    }
                    candidates.sort(function(a,b) { return b.score - a.score; });
                }
                var best = candidates.length > 0 ? candidates[0].el : document.body;
                var title = document.title || '';
                var content = best.innerHTML || best.innerText || '';
                window.webkit.messageHandlers.readerContent.postMessage({title: title, content: content, html: best.outerHTML});
            };
        })();
        """
        let readerScript = WKUserScript(source: readerJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(readerScript)

        let hoverJS = """
        (function() {
            document.addEventListener('mouseover', function(e) {
                var link = e.target.closest('a');
                if (link && link.href) {
                    window.webkit.messageHandlers.hoverLink.postMessage(link.href);
                }
            }, true);
            document.addEventListener('mouseout', function(e) {
                var link = e.target.closest('a');
                if (link) {
                    window.webkit.messageHandlers.hoverLink.postMessage('');
                }
            }, true);
        })();
        """
        let hoverScript = WKUserScript(source: hoverJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(hoverScript)

        webView = BrowserWKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        // Set the full Safari 26.5 UA on the WKWebView instance itself.
        // (See `applyDesktopSafariUA(to:)` for why this is on the view, not
        // the configuration.)
        Self.applyDesktopSafariUA(to: webView)
    }

    /// Applies a complete, real-looking macOS 26.5 Safari User-Agent.
    ///
    /// **Important macOS-vs-iOS quirk**: `WKWebViewConfiguration` does
    /// *not* expose a `customUserAgent` property (or KVC key) on macOS —
    /// it is iOS-only. Calling `config.setValue(_:forKey: "customUserAgent")`
    /// on macOS throws `NSUnknownKeyException` ("this class is not key value
    /// coding-compliant for the key customUserAgent"), which the Swift
    /// runtime bridges to a fatal `EXC_BREAKPOINT` and crashes the process.
    ///
    /// The macOS-correct path is to set `customUserAgent` on the **WKWebView
    /// instance** after it's been constructed (the property is KVC-compliant
    /// on the view, not the configuration). This static method must therefore
    /// be called from `init` **after** `webView = BrowserWKWebView(...)`.
    ///
    /// This is the **single source of truth** for the desktop UA — every
    /// BrowserState instance starts with the same string so the back-forward
    /// cache and WAFs see a consistent identity.
    static func applyDesktopSafariUA(to webView: WKWebView) {
        webView.setValue(_desktopSafariUA, forKey: "customUserAgent")
    }

    /// Cached desktop User-Agent for Desire.
    ///
    /// Desire is a real, native macOS browser built on WKWebView. We identify
    /// ourselves honestly: the UA matches what macOS 26.5 (Tahoe) Safari
    /// 26.5.2 emits today, with a single trailing `Desire/0.1` token so
    /// servers and WAFs can recognize the product family — *and* see the
    /// underlying WebKit/Safari so they don't treat us as a generic
    /// webview. Both halves matter:
    ///
    /// - `Version/26.5 Safari/605.1.15` is what Apple's WebKit actually
    ///   reports; the W3C-compatible `Mac OS X 10_15_7` OS-string is the
    ///   legacy form that WebKit still emits (changing it to a real
    ///   `26_5_2` will trigger Cloudflare's "unknown browser" rule).
    /// - `Desire/0.1` is the product token. The RFC 9110 user-agent
    ///   grammar allows appending a product comment, and honest browsers
    ///   (Chrome, Firefox, Edge, Brave) do exactly this. Hiding the product
    ///   name is a fingerprint-spoofing move that real browsers should not
    ///   do — it just gets WAFs to flag us.
    private static let _desktopSafariUA: String =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/26.5 Safari/605.1.15 "
        + "Desire/0.1"
}

struct WebView: NSViewRepresentable {
    @ObservedObject var state: BrowserState
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var passwordStore: PasswordStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var siteSettingsStore: SiteSettingsStore
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var httpsUpgradeEnabled: Bool = true
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onPageFinished: ((URL, String) -> Void)?
    var onElementPicked: ((String, String?) -> Void)?
    /// Forwarded from the `videoAdBlocked` WKScriptMessage handler.
    /// Parameters: (blockedCount, siteKey, actionKey). `siteKey` is one of
    /// "youtube" / "bilibili" / "tencent" / ... `actionKey` is optional
    /// ("skip" / "seek") — when set the count is already 1.
    var onVideoAdBlocked: ((Int, String?, String?) -> Void)?
    @ObservedObject var elementBlockStore: ElementBlockStore

    static let pickerJS = """
    (function() {
        var style = document.createElement('style');
        style.id = 'desire-picker-style';
        style.textContent = '.desire-picker-highlight{outline:3px solid #ff4444 !important;outline-offset:-1px !important;background:rgba(255,68,68,0.08) !important;cursor:crosshair !important}';
        document.head.appendChild(style);

        var hl;

        function getSelector(el) {
            if (el.id) return '#' + CSS.escape(el.id);
            var parts = [];
            while (el && el.nodeType === 1) {
                var tag = el.tagName.toLowerCase();
                if (el.id) { parts.unshift('#' + CSS.escape(el.id)); break; }
                var p = el.parentElement;
                if (p) {
                    var ch = Array.from(p.children);
                    var idx = ch.indexOf(el);
                    var same = ch.filter(function(c) { return c.tagName === el.tagName; });
                    if (same.length > 1) tag += ':nth-child(' + (idx + 1) + ')';
                }
                parts.unshift(tag);
                el = p;
            }
            return parts.join(' > ');
        }

        function getXPath(el) {
            if (el.id) return '//*[@id="' + el.id + '"]';
            var parts = [];
            while (el && el.nodeType === 1) {
                var tag = el.tagName.toLowerCase();
                if (el.id) { parts.unshift('*[@id="' + el.id + '"]'); break; }
                var p = el.parentElement;
                if (p) {
                    var ch = Array.from(p.children);
                    var idx = ch.indexOf(el) + 1;
                    tag += '[' + idx + ']';
                }
                parts.unshift(tag);
                el = p;
            }
            return '/' + parts.join('/');
        }

        function onOver(e) { if (hl) hl.classList.remove('desire-picker-highlight'); hl = e.target; hl.classList.add('desire-picker-highlight'); e.stopPropagation(); }
        function onOut(e) { if (hl) hl.classList.remove('desire-picker-highlight'); hl = null; e.stopPropagation(); }
        function onPick(e) {
            e.preventDefault(); e.stopPropagation();
            if (hl) hl.classList.remove('desire-picker-highlight');
            var sel = getSelector(e.target), xp = getXPath(e.target);
            document.head.removeChild(style);
            document.removeEventListener('mouseover', onOver, true);
            document.removeEventListener('mouseout', onOut, true);
            document.removeEventListener('click', onPick, true);
            window.webkit.messageHandlers.elementPicker.postMessage({cssSelector: sel, xpath: xp});
        }
        document.addEventListener('mouseover', onOver, true);
        document.addEventListener('mouseout', onOut, true);
        document.addEventListener('click', onPick, true);
    })();
    """

    static let exitPickerJS = """
    (function() {
        var s = document.getElementById('desire-picker-style');
        if (s) s.remove();
        var h = document.querySelector('.desire-picker-highlight');
        if (h) h.classList.remove('desire-picker-highlight');
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> BrowserWKWebView {
        let webView = state.webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.onOpenLinkInNewTab = { url in
            context.coordinator.parent.onOpenLinkInNewTab?(url)
        }
        context.coordinator.observe(webView)
        return webView
    }

    func updateNSView(_ nsView: BrowserWKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: BrowserWKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var parent: WebView
        var lastNavigatedURL: String?
        private var observations: [NSKeyValueObservation] = []
        private var activeDownloads: [ObjectIdentifier: DownloadInfo] = [:]
        private var pendingUpgrade: (https: URL, http: URL)?
        private var fallbackInProgress: Set<String> = []

        private struct DownloadInfo {
            let id: UUID
            let progressObservation: NSKeyValueObservation
        }

        init(_ parent: WebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            webView.configuration.userContentController.add(self, name: "audioState")
            webView.configuration.userContentController.add(self, name: "passwordDetect")
            webView.configuration.userContentController.add(self, name: "readerContent")
            webView.configuration.userContentController.add(self, name: "hoverLink")
            webView.configuration.userContentController.add(self, name: "elementPicker")
            webView.configuration.userContentController.add(self, name: "videoAdBlocked")

            observations = [
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.state.estimatedProgress = wv.estimatedProgress
                    }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                    if let title = wv.title, !title.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            self?.parent.state.pageTitle = title
                        }
                    }
                },
            ]
        }

        func stopObserving() {
            observations.removeAll()
            let wv = parent.state.webView
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "audioState")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "passwordDetect")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "readerContent")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "hoverLink")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "elementPicker")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "videoAdBlocked")
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.onOpenLinkInNewTab = nil
            wv.stopLoading()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "audioState", let playing = message.body as? Bool {
                parent.state.isPlayingAudio = playing
            } else if message.name == "passwordDetect", let dict = message.body as? [String: String],
                       let usernameName = dict["username"],
                       let host = parent.state.webView.url?.host {
                let entries = parent.passwordStore.find(domain: host)
                guard !entries.isEmpty else { return }
                let username = entries[0].username.replacingOccurrences(of: "'", with: "\\'")
                let password = entries[0].password.replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function() {
                    var f = document.querySelector('input[type=password]').closest('form');
                    if (!f) return;
                    var u = f.querySelector('input[name=\(usernameName)], input[id=\(usernameName)], input[type=text], input[type=email]');
                    if (u) u.value = '\(username)';
                    var p = f.querySelector('input[type=password]');
                    if (p) p.value = '\(password)';
                })();
                """
                parent.state.webView.evaluateJavaScript(js, completionHandler: nil)
            } else if message.name == "readerContent", let dict = message.body as? [String: String] {
                parent.state.readerTitle = dict["title"] ?? ""
                parent.state.readerContent = dict["html"] ?? dict["content"] ?? ""
            } else if message.name == "hoverLink", let url = message.body as? String {
                parent.state.hoveredLinkURL = url.isEmpty ? nil : url
            } else if message.name == "elementPicker", let dict = message.body as? [String: String],
                      let selector = dict["cssSelector"] {
                let xpath = dict["xpath"]
                parent.onElementPicked?(selector, xpath)
            } else if message.name == "videoAdBlocked", let dict = message.body as? [String: Any],
                      let count = dict["count"] as? Int, count > 0 {
                // Forward to the optional closure so the host can show a toast.
                parent.onVideoAdBlocked?(count, dict["site"] as? String, dict["action"] as? String)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.state.estimatedProgress = 0
            parent.state.lastError = nil
            parent.state.serverTrust = nil
            parent.state.hoveredLinkURL = nil
            // Workaround for WebKit Bug 313542 (https://bugs.webkit.org/show_bug.cgi?id=313542):
            // `customUserAgent` is not applied to the FIRST navigation request
            // when the URL is loaded via `load(_:)` — it only takes effect for
            // links the user taps inside the page. Re-applying it on every
            // provisional-navigation start ensures the very first request
            // (address-bar loads, programmatic loads, redirects) carries the
            // full Safari UA, which Cloudflare and other WAFs require to skip
            // the "由 Cloudflare 提供的性能和安全服务" challenge.
            BrowserState.applyDesktopSafariUA(to: webView)
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            parent.state.serverTrust = serverTrust

            var error: CFError?
            let isTrusted = SecTrustEvaluateWithError(serverTrust, &error)

            if isTrusted {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            } else {
                let host = challenge.protectionSpace.host
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Invalid Certificate")
                    let errDesc = error?.localizedDescription ?? String(localized: "Unknown Error")
                    alert.informativeText = String(localized: "The certificate for \(host) is not trusted.\n\n\(errDesc)")
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: String(localized: "Continue Anyway"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.state.isSecure = webView.url?.scheme == "https"
            pendingUpgrade = nil
            if let host = webView.url?.host {
                let savedZoom = parent.siteSettingsStore.zoom(for: host)
                if savedZoom != 1.0 {
                    webView.pageZoom = savedZoom
                    parent.state.pageZoom = savedZoom
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.state.estimatedProgress = 1
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.state.lastError = nil
            if let url = webView.url {
                parent.urlString = url.absoluteString
                lastNavigatedURL = url.absoluteString
                parent.state.isSecure = url.scheme == "https"
                parent.onPageFinished?(url, parent.state.pageTitle)
            }
            if let host = webView.url?.host, parent.siteSettingsStore.darkModeEnabled(for: host) {
                let js = """
                (function() {
                    if (!document.getElementById('desire-dark-mode')) {
                        var css = 'html{filter:invert(0.9)hue-rotate(180deg)}img,video,canvas,svg,[style*="background-image"]{filter:invert(1)hue-rotate(180deg)}';
                        var s = document.createElement('style');
                        s.id = 'desire-dark-mode';
                        s.textContent = css;
                        document.head.appendChild(s);
                    }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            if let host = webView.url?.host, let js = parent.state.videoAdBlocker?.pageScript(for: host) {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            if let host = webView.url?.host {
                let rules = parent.elementBlockStore.matchingRules(for: host)
                let cssSelectors = rules.map(\.cssSelector).filter { !$0.isEmpty }
                let xpathRules = rules.compactMap { $0.xpath }.filter { !$0.isEmpty }
                if !cssSelectors.isEmpty {
                    let css = cssSelectors.map { "\($0) { display: none !important; }" }.joined()
                    webView.evaluateJavaScript("""
                    (function() {
                        var s = document.createElement('style');
                        s.id = 'desire-blocked-selectors';
                        s.textContent = '\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))';
                        document.head.appendChild(s);
                    })();
                    """, completionHandler: nil)
                }
                for xpath in xpathRules {
                    let escaped = xpath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    webView.evaluateJavaScript("""
                    try {
                        var el = document.evaluate('\(escaped)', document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
                        if (el) el.style.display = 'none';
                    } catch(e) {}
                    """, completionHandler: nil)
                }
            }
            if parent.formAutofillStore.isConfigured {
                webView.evaluateJavaScript(parent.formAutofillStore.fillScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            // Store the underlying `Error` so ErrorPageView can map
            // `URLError.code` to category-specific copy (TLS, offline, …)
            // instead of just dumping the raw localized description.
            parent.state.lastError = error
        }

        // 处理新窗口/弹窗（Google 登录 OAuth 需要）
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // If this navigation was initiated by a back/forward gesture or
            // reload (WebKit's UI commands, our goBack()/goForward(), or a
            // user-triggered reload from the toolbar), don't intercept it.
            // The previous version called `webView.load(url)` here, which
            // produced a brand-new history entry on every back, breaking the
            // back button on sites like Bilibili where pages check history
            // depth / referrer for navigation state.
            if navigationAction.navigationType == .backForward ||
               navigationAction.navigationType == .reload {
                decisionHandler(.allow)
                return
            }

            // Frame-less navigation (e.g. target=_blank, window.open from JS).
            // Previously we called `webView.load()` and cancelled the original
            // request, which corrupted the back/forward list because the
            // programmatically-loaded URL became a new entry. Just let WebKit
            // handle it — for target=_blank WebKit will open a new tab/window
            // via the `webView(_:createWebViewWith:for:windowFeatures:)`
            // delegate method, and for other null-frame requests the
            // navigation is appended correctly to history.
            if navigationAction.targetFrame == nil {
                decisionHandler(.allow)
                return
            }

            // Cmd+点击链接 — 后台打开新标签
            if navigationAction.modifierFlags.contains(.command) {
                parent.onOpenLinkInNewTab?(url)
                decisionHandler(.cancel)
                return
            }

            // HTTPS 升级
            // Only upgrade when the user navigated to the URL by clicking a
            // link / typing into the address bar (`.linkActivated`,
            // `.other`, `.formSubmitted`). Skip for back/forward, reload, and
            // history restorations so the back button doesn't loop
            // http→https→http→https on sites that already do their own
            // scheme handling (Bilibili does this for /video/BV* redirects).
            if parent.httpsUpgradeEnabled,
               url.scheme == "http",
               navigationAction.targetFrame?.isMainFrame == true,
               !fallbackInProgress.contains(url.absoluteString),
               navigationAction.navigationType == .other ||
               navigationAction.navigationType == .linkActivated ||
               navigationAction.navigationType == .formSubmitted {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "https"
                if let https = comps?.url {
                    pendingUpgrade = (https: https, http: url)
                    webView.load(URLRequest(url: https))
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        private static let externalSchemes: Set<String> = [
            "mailto", "tel", "facetime", "sms",
            "maps", "itunes", "music", "podcasts",
            "appstore", "macappstore"
        ]

        // 无法展示的 MIME 类型（.pkg/.dmg/.zip 等直接文件链接）转为下载，
        // 否则 WebKit 会尝试渲染并失败（code 102 "frame load interrupted"）
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.state.lastError = error
            // Only fall back from HTTPS → HTTP when the *upgrade itself*
            // failed with a real network error. The previous version
            // triggered fallback on any non-cancelled error, which caused
            // problems when the user pressed back: the in-flight upgrade
            // navigation gets cancelled by the back action, the cancelled
            // (URLSession `-999`) error is non-cancelled under some macOS
            // builds, and we'd then issue a brand-new HTTP request on top
            // of the back navigation, corrupting history. Restrict the
            // fallback to a small set of well-known error codes that only
            // fire when the server itself couldn't be reached over HTTPS.
            guard let upgrade = pendingUpgrade,
                  let urlError = error as? URLError else { return }
            switch urlError.code {
            case .serverCertificateUntrusted,
                 .secureConnectionFailed,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed:
                pendingUpgrade = nil
                fallbackInProgress.insert(upgrade.http.absoluteString)
                webView.load(URLRequest(url: upgrade.http))
            case .cancelled:
                // The user navigated away (back, forward, reload) before
                // the upgrade finished. Don't fall back — clearing the
                // pending state is enough.
                pendingUpgrade = nil
            default:
                pendingUpgrade = nil
            }
        }

        // MARK: - WKUIDelegate - 权限请求

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let pType: PermissionType = switch type {
            case .camera: .camera
            case .microphone: .microphone
            case .cameraAndMicrophone: .cameraAndMicrophone
            @unknown default: .camera
            }
            let host = origin.host
            if let saved = parent.permissionStore.decision(for: host, type: pType) {
                decisionHandler(saved == .allow ? .grant : .deny)
                return
            }
            let deviceName: String = switch type {
            case .camera: String(localized: "Camera")
            case .microphone: String(localized: "Microphone")
            case .cameraAndMicrophone: String(localized: "Camera and Microphone")
            @unknown default: String(localized: "Media Device")
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(host) wants to access your \(deviceName)")
            alert.informativeText = String(localized: "Allow this website to access your \(deviceName)?")
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Deny"))
            let checkbox = NSButton(checkboxWithTitle: String(localized: "Remember this decision"), target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if checkbox.state == .on {
                parent.permissionStore.set(host: host, type: pType, decision: response == .alertFirstButtonReturn ? .allow : .deny)
            }
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let host = origin.host
            if let saved = parent.permissionStore.decision(for: host, type: .geolocation) {
                decisionHandler(saved == .allow ? .grant : .deny)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(host) wants to access your location")
            alert.informativeText = String(localized: "Allow this website to access your location?")
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Deny"))
            let checkbox = NSButton(checkboxWithTitle: String(localized: "Remember this decision"), target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if checkbox.state == .on {
                parent.permissionStore.set(host: host, type: .geolocation, decision: response == .alertFirstButtonReturn ? .allow : .deny)
            }
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false
            guard panel.runModal() == .OK else { completionHandler(nil); return }
            completionHandler(panel.urls)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = prompt
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return textField.stringValue
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            let filename = download.originalRequest?.url?.lastPathComponent ?? String(localized: "Download")
            let id = parent.downloadStore.add(item: DownloadItem(
                id: UUID(),
                filename: filename,
                fileURL: nil,
                totalBytes: 0,
                downloadedBytes: 0,
                state: .inProgress,
                error: nil,
                cancel: { [weak download] in download?.cancel() }
            ))
            let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    self?.parent.downloadStore.updateProgress(
                        id: id,
                        totalBytes: progress.totalUnitCount,
                        downloadedBytes: progress.completedUnitCount
                    )
                }
            }
            activeDownloads[ObjectIdentifier(download)] = DownloadInfo(id: id, progressObservation: observation)
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let destination = parent.downloadStore.uniqueURL(for: suggestedFilename)
            if let info = activeDownloads[ObjectIdentifier(download)] {
                parent.downloadStore.setDestination(
                    id: info.id,
                    filename: suggestedFilename,
                    fileURL: destination,
                    totalBytes: response.expectedContentLength
                )
            }
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
                parent.downloadStore.complete(id: info.id)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
                parent.downloadStore.fail(id: info.id, message: error.localizedDescription)
            }
        }
    }
}
