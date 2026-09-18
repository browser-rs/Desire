import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Orchestrates browsing actions that cross Store boundaries (persistence,
/// JS execution, find, zoom, bookmark toggle, screenshot) — logic that
/// previously lived inline in `ContentView`'s action methods, violating
/// AGENTS.md's "禁止在 View 文件里定义业务逻辑".
///
/// ContentView holds one instance as `@StateObject` and delegates every
/// action through it. The coordinator doesn't own UI-local state (which
/// sheet is open, which field is focused) — that stays on ContentView; it
/// only owns business state that crosses Stores.
@MainActor
class BrowsingActions: ObservableObject {
    let tabManager: TabManager
    let settings: Settings
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let siteSettingsStore: SiteSettingsStore
    let searchHistoryStore: SearchHistoryStore
    let elementBlockStore: ElementBlockStore
    let devToolsStore: DevToolsStore
    /// Needed by session restore and fresh-tab creation (both thread the
    /// blockers into every new tab's webview configuration).
    let contentBlocker: ContentBlockerStore
    let videoAdBlocker: VideoAdBlocker

    // MARK: - Published results (observed by ContentView)

    /// Find-in-page state published here so ContentView doesn't need separate
    /// @State for it.
    @Published var findHasMatch = false
    @Published var findMatchCount = 0
    @Published var findCurrentIndex = 0

    /// Toast messages surfaced for ContentView's overlay rendering.
    @Published var screenshotToast: String?
    @Published var undoRule: BlockedElementRule?
    @Published var undoCssSelector = ""
    @Published var undoXpath: String?

    init(
        tabManager: TabManager,
        settings: Settings,
        bookmarkStore: BookmarkStore,
        historyStore: HistoryStore,
        siteSettingsStore: SiteSettingsStore,
        searchHistoryStore: SearchHistoryStore,
        elementBlockStore: ElementBlockStore,
        devToolsStore: DevToolsStore,
        contentBlocker: ContentBlockerStore,
        videoAdBlocker: VideoAdBlocker
    ) {
        self.tabManager = tabManager
        self.settings = settings
        self.bookmarkStore = bookmarkStore
        self.historyStore = historyStore
        self.siteSettingsStore = siteSettingsStore
        self.searchHistoryStore = searchHistoryStore
        self.elementBlockStore = elementBlockStore
        self.devToolsStore = devToolsStore
        self.contentBlocker = contentBlocker
        self.videoAdBlocker = videoAdBlocker
    }

    // MARK: - Launch tabs

    /// Opens a single fresh tab with the current settings.
    func openFreshTab() {
        tabManager.addTab(
            javaScriptEnabled: settings.isJavaScriptEnabled,
            contentBlocker: contentBlocker,
            videoAdBlocker: videoAdBlocker,
            autoPlayPolicy: settings.autoPlayPolicy,
            newTabPosition: settings.newTabPosition
        )
    }
}

// MARK: - Navigation & bookmarks

extension BrowsingActions {
    /// Navigates a tab based on raw address-bar text. Resolution goes through
    /// `URLResolution` — the SAME layer the suggestion preview uses, so the
    /// dropdown's promise is exactly what happens here. A failed URL parse
    /// falls back to search instead of silently doing nothing; searches are
    /// recorded to history (unless incognito) only when they actually run.
    func navigateToURL(_ input: String, for tab: Tab) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = URLResolution.resolve(text, settings: settings) else { return }

        // Always target the ACTIVE window's selected tab — never a stale
        // captured reference (fixes multi-tab navigation to the wrong tab).
        let target = tabManager.selectedTab ?? tab

        let urlString: String
        switch destination {
        case .url(let resolved):
            urlString = resolved
        case .search(let query, let engine):
            guard let searchURL = URLResolution.searchURL(query: query, target: engine) else { return }
            if !target.isIncognito {
                searchHistoryStore.add(query: query, engine: engine.displayName)
            }
            urlString = searchURL.absoluteString
        }
        guard let url = URL(string: urlString) else { return }
        target.isOnNewTabPage = false
        target.urlString = urlString
        target.browser.webView.load(URLRequest(url: url))
    }

    func loadHome(for tab: Tab) {
        guard let url = URL(string: settings.homePage) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = settings.homePage
        tab.browser.webView.load(URLRequest(url: url))
    }

    /// Adds or removes the current page's bookmark. Returns whether the
    /// bookmark was added (`true`) or removed (`false`); nil when there was
    /// nothing to toggle (new-tab page, no URL).
    @discardableResult
    func toggleBookmark() -> Bool? {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return nil }
        let urlString = url.absoluteString
        if let existing = bookmarkStore.find(url: urlString) {
            bookmarkStore.remove(existing)
            return false
        } else {
            bookmarkStore.add(title: tab.browser.pageTitle, url: urlString)
            return true
        }
    }
}

// MARK: - Zoom

extension BrowsingActions {
    func zoom(by delta: Double) {
        guard let tab = tabManager.selectedTab else { return }
        let newZoom = min(5.0, max(0.5, tab.browser.pageZoom + delta))
        tab.browser.pageZoom = newZoom
        tab.browser.webView.pageZoom = newZoom
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(newZoom, for: host)
        }
    }

    func zoom(to value: Double) {
        guard let tab = tabManager.selectedTab else { return }
        tab.browser.pageZoom = value
        tab.browser.webView.pageZoom = value
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(value, for: host)
        }
    }
}

// MARK: - Print & screenshot

extension BrowsingActions {
    func printPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.topMargin = 20
        printInfo.bottomMargin = 20
        printInfo.leftMargin = 20
        printInfo.rightMargin = 20
        let operation = tab.browser.webView.printOperation(with: printInfo)
        operation.run()
    }

    func startScreenshot(saveFolder: URL) {
        ScreenshotSession.start(saveFolder: saveFolder) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .cancelled: break
                case .saved(let url):
                    self.screenshotToast = String(format: String(localized: "Saved to %@"), url.lastPathComponent)
                case .copied:
                    self.screenshotToast = String(localized: "Copied to clipboard")
                }
                if self.screenshotToast != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.screenshotToast = nil
                    }
                }
            }
        }
    }

    func refreshMediaQueries(for tab: Tab, completion: @escaping ([MediaQueryItem]) -> Void) {
        tab.browser.webView.evaluateJavaScript(mediaQueryExtractorJS) { result, _ in
            if let rules = result as? [[String: Any]] {
                let items = rules.map {
                    MediaQueryItem(query: $0["query"] as? String ?? "", isActive: $0["active"] as? Bool ?? false)
                }
                completion(items)
            }
        }
    }

    func captureResponsiveScreenshot(for tab: Tab) {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(origin: .zero, size: tab.responsiveConfig.effectiveSize)
        tab.browser.webView.takeSnapshot(with: snapConfig) { image, error in
            guard let image, error == nil else { return }
            let panel = NSSavePanel()
            panel.title = String(localized: "Save Responsive Screenshot")
            panel.nameFieldStringValue = "responsive-\(Int(tab.responsiveConfig.effectiveSize.width))x\(Int(tab.responsiveConfig.effectiveSize.height)).png"
            panel.allowedContentTypes = [.png]
            panel.begin { response in
                if response == .OK, let url = panel.url,
                   let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData) {
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    func captureFullPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let config = WKPDFConfiguration()
        tab.browser.webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let pdfData):
                let panel = NSSavePanel()
                panel.title = String(localized: "Save Full Page PDF")
                panel.nameFieldStringValue = "\(tab.displayTitle).pdf"
                panel.allowedContentTypes = [.pdf]
                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        try? pdfData.write(to: url)
                    }
                }
            case .failure: break
            }
        }
    }

    func togglePictureInPicture() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) return;
            if (document.pictureInPictureElement) {
                document.exitPictureInPicture();
            } else if (v.readyState >= 2) {
                v.requestPictureInPicture();
            }
        })();
        """
        tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Toggles dark-mode override for the current page via per-site CSS
    /// injection and `siteSettingsStore`.
    func toggleDarkMode(for tab: Tab) {
        guard let host = tab.browser.webView.url?.host else { return }
        let enabled = !siteSettingsStore.darkModeEnabled(for: host)
        siteSettingsStore.setDarkMode(enabled, for: host)
        let js = """
        (function() {
            var el = document.getElementById('desire-dark-mode');
            if (\(enabled)) {
                if (!el) {
                    var css = 'html{filter:invert(0.9)hue-rotate(180deg)}img,video,canvas,svg,[style*="background-image"]{filter:invert(1)hue-rotate(180deg)}';
                    var s = document.createElement('style');
                    s.id = 'desire-dark-mode';
                    s.textContent = css;
                    document.head.appendChild(s);
                }
            } else {
                if (el) el.remove();
            }
        })();
        """
        tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - Find in page

extension BrowsingActions {
    func findAll(query: String, in tab: Tab) {
        let config = WKFindConfiguration()
        config.wraps = false
        tab.browser.webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.findHasMatch = result.matchFound
            if result.matchFound { self.findCurrentIndex = 0 }
        }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        tab.browser.webView.evaluateJavaScript("""
        (function() {
            var t = '\(escaped)';
            if (!t) return 0;
            var r = new RegExp(t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
            var c = 0, walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            while (walk.nextNode()) { c += (walk.nodeValue.match(r) || []).length; }
            return c;
        })()
        """) { [weak self] value, _ in
            if let count = value as? Int {
                DispatchQueue.main.async {
                    self?.findMatchCount = count
                }
            }
        }
    }

    func findNext(query: String, in tab: Tab) {
        let config = WKFindConfiguration()
        config.wraps = true
        tab.browser.webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.findHasMatch = result.matchFound
            if result.matchFound && self.findMatchCount > 0 {
                self.findCurrentIndex = (self.findCurrentIndex + 1) % self.findMatchCount
            }
        }
    }

    func findPrevious(query: String, in tab: Tab) {
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        tab.browser.webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.findHasMatch = result.matchFound
            if result.matchFound && self.findMatchCount > 0 {
                self.findCurrentIndex = (self.findCurrentIndex - 1 + self.findMatchCount) % self.findMatchCount
            }
        }
    }
}

// MARK: - Element blocking

extension BrowsingActions {
    func handleElementPicked(cssSelector: String, xpath: String?, in tab: Tab) {
        guard let host = tab.browser.webView.url?.host else {
            tab.browser.isPickingElement = false
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Block this element?")
        alert.informativeText = "CSS: \(cssSelector)"
        if let xp = xpath { alert.informativeText += "\nXPath: \(xp)" }
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Block"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let rule = BlockedElementRule(urlPattern: host, cssSelector: cssSelector, xpath: xpath)
            elementBlockStore.add(cssSelector: cssSelector, xpath: xpath, urlPattern: host)
            let escapedCss = cssSelector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            tab.browser.webView.evaluateJavaScript("""
            (function() {
                var s = document.createElement('style');
                s.id = 'desire-blocked-\(rule.id.uuidString)';
                s.textContent = '\(escapedCss) { display: none !important; }';
                document.head.appendChild(s);
            })();
            """, completionHandler: nil)
            undoRule = rule
            undoCssSelector = cssSelector
            undoXpath = xpath
        }
        tab.browser.isPickingElement = false
    }
}

// MARK: - Dev tools

extension BrowsingActions {
    func toggleDevMode() {
        devToolsStore.toggleDevMode()
    }

    func inspectElement() {
        if let tab = tabManager.selectedTab, !tab.isOnNewTabPage {
            tab.browser.webView.requestInspector()
        }
    }
}

// MARK: - Make webview

extension BrowsingActions {
    /// Constructs the `WebView` for `tab`, wiring all store callbacks.
    /// Kept here (not in a View builder) because the callbacks touch
    /// multiple stores.
    func makeWebView(
        for tab: Tab,
        downloadStore: DownloadStore,
        passwordStore: PasswordStore,
        formAutofillStore: FormAutofillStore,
        permissionStore: PermissionStore,
        pluginStore: PluginStore,
        videoAdBlocker: VideoAdBlocker,
        contentBlocker: ContentBlockerStore,
        settings: Settings,
        aiSession: AgentSessionStore,
        devToolsStore: DevToolsStore,
        elementBlockStore: ElementBlockStore,
        onElementPicked: @escaping (String, String?, Tab) -> Void
    ) -> WebView {
        tab.browser.onAIElementPicked = { selector, html in
            aiSession.addContext(html: html, selector: selector)
        }
        aiSession.setWebView(tab.browser.webView)
        return WebView(
            state: tab.browser,
            downloadStore: downloadStore,
            passwordStore: passwordStore,
            formAutofillStore: formAutofillStore,
            permissionStore: permissionStore,
            siteSettingsStore: siteSettingsStore,
            devToolsStore: devToolsStore,
            urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
            httpsUpgradeEnabled: settings.httpsUpgradeEnabled,
            extensionManager: nil,
            onOpenLinkInNewTab: { [weak self] url in
                self?.tabManager.addTab(url: url.absoluteString,
                                        javaScriptEnabled: settings.isJavaScriptEnabled,
                                        contentBlocker: contentBlocker,
                                        videoAdBlocker: videoAdBlocker,
                                        autoPlayPolicy: settings.autoPlayPolicy,
                                        newTabPosition: settings.newTabPosition)
            },
            onSearchText: { [weak self] text in
                guard let self else { return }
                // Route through the shared resolver so a "Search …" menu pick
                // on URL-looking text navigates instead of searching.
                let target: String
                switch URLResolution.resolve(text, settings: self.settings) {
                case .url(let urlString):
                    target = urlString
                case .search(let query, let engine):
                    target = URLResolution.searchURL(query: query, target: engine)?.absoluteString ?? text
                case nil:
                    return
                }
                self.tabManager.addTab(url: target,
                                       javaScriptEnabled: settings.isJavaScriptEnabled,
                                       contentBlocker: contentBlocker,
                                       videoAdBlocker: videoAdBlocker,
                                       autoPlayPolicy: settings.autoPlayPolicy,
                                       newTabPosition: settings.newTabPosition)
            },
            onPageFinished: { [weak self] url, title in
                videoAdBlocker.resetCount()
                if tab.suppressHistoryOnce {
                    tab.suppressHistoryOnce = false
                } else if !tab.isIncognito {
                    self?.historyStore.addEntry(url: url.absoluteString, title: title)
                }
                pluginStore.inject(into: tab.browser.webView, for: url)
            },
            onElementPicked: { cssSelector, xpath in
                onElementPicked(cssSelector, xpath, tab)
            },
            onVideoAdBlocked: { count, site, action in
                // Toast handled in ContentView (UI-local state)
            },
            onInspectedElement: { element in
                devToolsStore.setInspectedElement(element)
            },
            elementBlockStore: elementBlockStore
        )
    }
}
