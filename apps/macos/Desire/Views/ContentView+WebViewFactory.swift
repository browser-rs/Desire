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
        // 只绑定选中标签的 webview（0.3.9）：分屏打开时本工厂每帧被调
        // 两次（主栏 + partner 栏），partner 的调用曾把会话 webview 每帧
        // 覆盖回去——setWebView 主/partner 震荡 = 每帧发布 + Agent 上下
        // 文标签翻转（也是拖动卡顿源之一）。
        if tabManager.selectedTab?.id == tab.id {
            aiSession.setWebView(tab.browser.webView)
        }
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
            tabID: tab.id,
            urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
            httpsUpgradeEnabled: settings.httpsUpgradeEnabled,
            sponsorBlockEnabled: settings.sponsorBlockSkip,
            sponsorBlockCategories: settings.sponsorCategories,
            onOpenLinkInNewTab: { url in
                // Inherit the source tab's identity — "open in new tab" from
                // a private/container tab must not leak into the default store.
                tabManager.addTab(url: url.absoluteString, incognito: tab.isIncognito, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition, containerID: tab.containerID, makeActive: !settings.openLinksInBackground)
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
                // AI 自动广告清理（开关开时页面加载完自动扫描拦截高置信候选）。
                AutoAdClean.shared.handlePageLoad(webView: tab.browser.webView, url: url)
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
                // **注入必须跳出 didFinish 调用栈**（2026-10-02 实测）：didFinish
                // 回调里 evaluate 进的内容脚本，其 postMessage 会**静默丢失**
                //（延时 1.5s 再发就能到——WebKit 在导航回调执行期间不投递
                // 脚本消息）。下一拍注入，DOM 已就绪不受影响。
                // handler 未就绪（新 webview 首载快于 SwiftUI 建 representable）
                // 时同样会静默丢失——挂起到注册完成后补跑
                // （见 BrowserState.pendingPluginInjectURL）。
                // tabs.onUpdated 广播（页面世界 + 各 background 页）：didFinish
                // 近似 Chrome 的 status=complete + url/title 变化。
                let changeInfo: [String: Any] = ["status": "complete",
                                                 "url": url.absoluteString, "title": title]
                let tabPayload: [String: Any] = [
                    "id": tab.id.uuidString,
                    "index": tabManager.tabs.firstIndex(where: { $0.id == tab.id }) ?? -1,
                    "url": url.absoluteString, "title": title,
                    "active": tabManager.selectedTab?.id == tab.id,
                    "incognito": tab.isIncognito, "pinned": tab.isPinned,
                ]
                ExtensionEventHub.shared.fireRaw(
                    "tabs.onUpdated", payload: [tab.id.uuidString, changeInfo, tabPayload])
                PluginBackgroundRuntime.shared.fireAll(
                    event: "tabs.onUpdated", payload: [tab.id.uuidString, changeInfo, tabPayload])
                let injectURL = url
                DispatchQueue.main.async {
                    if tab.browser.areExtHandlersRegistered {
                        pluginStore.inject(into: tab.browser.webView, for: injectURL, tabID: tab.id)
                    } else {
                        tab.browser.pendingPluginInjectURL = injectURL
                    }
                }
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
                } else if action == "click-hijack" {
                    actionSuffix = String(localized: "（首次点击防护）")
                } else {
                    actionSuffix = ""
                }
                videoAdBlockerToast = String(format: String(localized: "已拦截 %d 个 %@ 广告%@"), count, siteName, actionSuffix)
                scheduleVideoAdBlockerToastReset()
                // 聚合统计（广告拦截面板的数据源）：站点 key 原样入库。
                AdBlockStatsStore.shared.record(count: count, site: site, action: action)
            },
            onCookieGuardHandled: { pref, label in
                // Cookie 弹窗自动处理命中（0.6.5）：toast 告知（视频拦截同款通道）。
                let verb = pref == "reject" ? String(localized: "已拒绝") : String(localized: "已接受")
                videoAdBlockerToast = String(localized: "Cookie 弹窗\(verb)（\(label)）")
                scheduleVideoAdBlockerToastReset()
            },
            onInspectedElement: { element in
                devToolsStore.setInspectedElement(element)
            },
            onQueryTabs: {
                // WebExtension tabs.query：宿主窗口的标签快照。
                tabManager.tabs.enumerated().map { index, t in
                    [
                        "id": t.id.uuidString,
                        "index": index,
                        "url": t.browser.webView.url?.absoluteString ?? t.urlString,
                        "title": t.browser.pageTitle,
                        "active": index == tabManager.selectedIndex,
                        "incognito": t.isIncognito,
                        "pinned": t.isPinned,
                    ] as [String: Any]
                }
            },
            onTabManager: { [weak tabManager] in tabManager },
            onCreateTab: { urlString in
                // 继承来源标签身份（与"在新标签打开链接"一致）。
                tabManager.addTab(url: urlString, incognito: tab.isIncognito, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition, containerID: tab.containerID)
            },
            onRemoveTab: { idString in
                guard let id = UUID(uuidString: idString),
                      let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
                tabManager.closeTab(at: index)
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
        // 首次点击防护按域名上报（非内置站点）：直接把域名显示出来，
        // 用户一眼知道是哪个站拦下的。
        default: (key?.isEmpty == false ? key! : String(localized: "视频"))
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
