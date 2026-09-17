import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension ContentView {
    func makeWebView(for tab: Tab) -> WebView {
        tab.browser.onAIElementPicked = { selector, html in
            aiSession.addContext(html: html, selector: selector)
        }
        aiSession.setWebView(tab.browser.webView)
        tab.browser.webView.onOpenInContainer = { url, container in
            tabManager.addTab(
                url: url.absoluteString,
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                newTabPosition: settings.newTabPosition,
                containerID: container.id
            )
        }
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
            onOpenLinkInNewTab: { url in
                // Inherit the source tab's identity — "open in new tab" from
                // a private/container tab must not leak into the default store.
                tabManager.addTab(url: url.absoluteString, incognito: tab.isIncognito, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition, containerID: tab.containerID)
            },
            onSearchText: { text in
                // Right-click "Search …": route through the shared resolver
                // so URL-looking selection navigates instead of searching.
                guard let destination = URLResolution.resolve(text, settings: settings) else { return }
                let target: String
                switch destination {
                case .url(let urlString):
                    target = urlString
                case .search(let query, let engine):
                    target = URLResolution.searchURL(query: query, target: engine)?.absoluteString ?? text
                }
                tabManager.addTab(url: target, incognito: tab.isIncognito, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition, containerID: tab.containerID)
            },
            onPageFinished: { url, title in
                // Reset per-page counter so the toast reflects this navigation.
                videoAdBlocker.resetCount()
                if tab.suppressHistoryOnce {
                    tab.suppressHistoryOnce = false
                } else if !tab.isIncognito {
                    historyStore.addEntry(url: url.absoluteString, title: title)
                    // WebKit's title update races didFinish — correct the
                    // entry once the real page title lands (stale entries
                    // showed the app placeholder "Desire").
                    let targetURL = url.absoluteString
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        guard tab.browser.webView.url?.absoluteString == targetURL,
                              let fresh = tab.browser.webView.title, fresh != title else { return }
                        historyStore.updateEntryTitle(url: targetURL, title: fresh)
                    }
                }
                pluginStore.inject(into: tab.browser.webView, for: url)
            },
            onElementPicked: { cssSelector, xpath in
                handleElementPicked(cssSelector: cssSelector, xpath: xpath, in: tab)
            },
            onVideoAdBlocked: { count, site, action in
                let siteName = Self.videoSiteDisplayName(site)
                let actionSuffix: String
                if action == "skip" {
                    actionSuffix = String(localized: "（已跳过）")
                } else if action == "seek" {
                    actionSuffix = String(localized: "（已快进）")
                } else {
                    actionSuffix = ""
                }
                videoAdBlockerToast = String(format: String(localized: "已拦截 %d 个 %@ 广告%@"), count, siteName, actionSuffix)
                scheduleVideoAdBlockerToastReset()
            },
            onInspectedElement: { element in
                devToolsStore.setInspectedElement(element)
            },
            elementBlockStore: elementBlockStore
        )
    }

    /// Maps the JS `site` key (e.g. "youtube") to a localized display name.
    private static func videoSiteDisplayName(_ key: String?) -> String {
        switch key {
        case "youtube": String(localized: "YouTube")
        case "bilibili": String(localized: "Bilibili")
        case "tencent": String(localized: "腾讯视频")
        case "iqiyi": String(localized: "爱奇艺")
        case "youku": String(localized: "优酷")
        case "mgtv": String(localized: "芒果TV")
        case "tiktok": String(localized: "TikTok")
        case "twitter": String(localized: "X")
        default: String(localized: "视频")
        }
    }

    /// Schedules the video-ad-blocker toast to disappear after 2.5s.
    /// Uses an id-based schedule to allow overlapping updates (latest wins).
    func scheduleVideoAdBlockerToastReset() {
        let snapshot = videoAdBlockerToast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if videoAdBlockerToast == snapshot {
                videoAdBlockerToast = nil
            }
        }
    }
    func handleElementPicked(cssSelector: String, xpath: String?, in tab: Tab) { b.handleElementPicked(cssSelector: cssSelector, xpath: xpath, in: tab) }
}
