import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserToolProvider {
    weak var tabManager: TabManager?
    weak var bookmarkStore: BookmarkStore?
    weak var historyStore: HistoryStore?
    weak var contentBlocker: ContentBlocker?
    weak var readingListStore: ReadingListStore?
    weak var downloadStore: DownloadStore?
    weak var siteSettingsStore: SiteSettingsStore?
    weak var settings: Settings?
    weak var videoAdBlocker: VideoAdBlocker?
    weak var pluginStore: PluginStore?
    weak var elementBlockStore: ElementBlockStore?
    weak var tabGroupStore: TabGroupStore?
    weak var quickDialStore: QuickDialStore?

    static var toolDefs: [AIToolDef] {
        [
            // --- Page reading ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageText", description: "Get the visible text content of the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageHTML", description: "Get the full HTML of the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageTitle", description: "Get the page title",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "screenshot", description: "Take a screenshot of the current viewport, returns base64 PNG",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getSelectedText", description: "Get the text currently selected by the user on the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Navigation ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "navigate", description: "Navigate to a URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "The URL to navigate to")], required: ["url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goBack", description: "Go back in history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goForward", description: "Go forward in history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab management ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "newTab", description: "Open a new tab, optionally navigated to a URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "URL to load in the new tab (optional)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "closeTab", description: "Close the current or specified tab by index (0-based)",
                parameters: AIJSONSchema(type: "object", properties: ["index": AIJSONSchemaValue(type: "number", description: "Tab index to close (optional, defaults to current)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listTabs", description: "List all open tabs with their titles and indices",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "switchTab", description: "Switch to a tab by its index (0-based)",
                parameters: AIJSONSchema(type: "object", properties: ["index": AIJSONSchemaValue(type: "number", description: "Tab index to switch to")], required: ["index"])
            )),

            // --- Bookmarks ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addBookmark", description: "Bookmark the current page",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listBookmarks", description: "List all bookmarks with titles and URLs",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeBookmark", description: "Remove a bookmark by its URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "URL of the bookmark to remove")], required: ["url"])
            )),

            // --- History ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getHistory", description: "Get recent browsing history entries",
                parameters: AIJSONSchema(type: "object", properties: ["count": AIJSONSchemaValue(type: "number", description: "Number of entries to return (default 20)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "clearHistory", description: "Clear all browsing history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Page controls ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "findInPage", description: "Search for text on the current page",
                parameters: AIJSONSchema(type: "object", properties: ["text": AIJSONSchemaValue(type: "string", description: "Text to search for")], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleDarkMode", description: "Toggle dark mode for the current website",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleReaderMode", description: "Toggle reader mode for the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "zoomIn", description: "Zoom in the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "zoomOut", description: "Zoom out the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "resetZoom", description: "Reset zoom to default (100%)",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Content blockers ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleAdBlocking", description: "Enable or disable ad blocking",
                parameters: AIJSONSchema(type: "object", properties: ["enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleTrackingProtection", description: "Enable or disable tracking protection",
                parameters: AIJSONSchema(type: "object", properties: ["enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),

            // --- Reading list ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addToReadingList", description: "Add the current page to reading list",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),

            // --- Downloads ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listDownloads", description: "List all downloads with filenames and status",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Plugins ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listPlugins", description: "List all installed user scripts and plugins",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "togglePlugin", description: "Enable or disable a plugin by name",
                parameters: AIJSONSchema(type: "object", properties: [
                    "name": AIJSONSchemaValue(type: "string", description: "Plugin name"),
                    "enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable"),
                ], required: ["name", "enabled"])
            )),

            // --- Element blocker ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listBlockedElements", description: "List all blocked element rules",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "unblockElement", description: "Remove a blocked element rule by its CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string", description: "CSS selector to unblock")], required: ["selector"])
            )),

            // --- Responsive design ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleResponsiveMode", description: "Toggle responsive design mode, optionally setting a device preset (iPhone SE, iPhone 14 Pro, iPhone 14 Pro Max, iPad 10, iPad Pro 12.9)",
                parameters: AIJSONSchema(type: "object", properties: ["device": AIJSONSchemaValue(type: "string", description: "Device preset name (optional)")])
            )),

            // --- Picture in Picture ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "togglePictureInPicture", description: "Toggle picture-in-picture for the current video",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab groups ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listTabGroups", description: "List all tab groups",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addTabToGroup", description: "Add the current tab to a tab group",
                parameters: AIJSONSchema(type: "object", properties: ["groupName": AIJSONSchemaValue(type: "string", description: "Name of the tab group")], required: ["groupName"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeTabFromGroup", description: "Remove the current tab from its tab group",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Print & PDF ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "printPage", description: "Print the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "saveAsPDF", description: "Save the current page as a PDF file",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Quick Dials ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listQuickDials", description: "List quick dial shortcuts on the new tab page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addQuickDial", description: "Add a quick dial shortcut",
                parameters: AIJSONSchema(type: "object", properties: [
                    "title": AIJSONSchemaValue(type: "string", description: "Display title"),
                    "url": AIJSONSchemaValue(type: "string", description: "URL"),
                ], required: ["title", "url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeQuickDial", description: "Remove a quick dial shortcut by title",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Title of the quick dial to remove")], required: ["title"])
            )),

            // --- Search engine ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "setSearchEngine", description: "Change the default search engine. Options: google, duckduckgo, bing, baidu",
                parameters: AIJSONSchema(type: "object", properties: ["engine": AIJSONSchemaValue(type: "string", description: "Search engine name")], required: ["engine"])
            )),

            // --- Sidebar ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleSidebar", description: "Toggle the sidebar (bookmarks, history, reading list)",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- DOM interaction ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "click", description: "Click an element identified by CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "fill", description: "Fill a form field with a value",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the input"),
                    "value": AIJSONSchemaValue(type: "string", description: "Value to fill"),
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "select", description: "Select an option from a dropdown",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the select element"),
                    "value": AIJSONSchemaValue(type: "string", description: "Value to select"),
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "scroll", description: "Scroll the page to coordinates",
                parameters: AIJSONSchema(type: "object", properties: [
                    "x": AIJSONSchemaValue(type: "number", description: "Horizontal scroll position"),
                    "y": AIJSONSchemaValue(type: "number", description: "Vertical scroll position"),
                ], required: ["x", "y"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "hover", description: "Hover over an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "focus", description: "Focus an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "extract", description: "Extract text content from elements matching a CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "findElements", description: "Find elements by CSS selector, returns count and first match text",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),

            // --- Utilities ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "wait", description: "Wait for a specified number of milliseconds",
                parameters: AIJSONSchema(type: "object", properties: ["ms": AIJSONSchemaValue(type: "number", description: "Milliseconds to wait")], required: ["ms"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "waitForElement", description: "Wait for an element to appear in the DOM",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string"),
                    "timeout": AIJSONSchemaValue(type: "number", description: "Max milliseconds to wait"),
                ], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "executeJS", description: "Execute arbitrary JavaScript code in the page context and return the result",
                parameters: AIJSONSchema(type: "object", properties: ["code": AIJSONSchemaValue(type: "string", description: "JavaScript code")], required: ["code"])
            )),
        ]
    }

    func execute(_ call: AIToolCall, in webView: WKWebView) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
        switch call.function.name {
        // --- Page reading ---
        case "getPageText":
            return await eval(webView, "document.body.innerText")
        case "getPageHTML":
            return await eval(webView, "document.documentElement.outerHTML")
        case "getPageTitle":
            return await eval(webView, "document.title")
        case "screenshot":
            return await captureScreenshot(webView)
        case "getSelectedText":
            return await eval(webView, "window.getSelection().toString()")

        // --- Navigation ---
        case "navigate":
            guard let url = args["url"] as? String, let u = URL(string: url) else { return "Invalid URL" }
            webView.load(URLRequest(url: u))
            return "Navigated to \(url)"
        case "goBack":
            guard webView.canGoBack else { return "Cannot go back" }
            webView.goBack()
            return "Going back"
        case "goForward":
            guard webView.canGoForward else { return "Cannot go forward" }
            webView.goForward()
            return "Going forward"

        // --- Tab management ---
        case "newTab":
            let url = args["url"] as? String
            let jsEnabled = settings?.isJavaScriptEnabled ?? true
            tabManager?.addTab(url: url, javaScriptEnabled: jsEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker)
            return url.map { "Opened new tab with \($0)" } ?? "Opened new tab"

        case "closeTab":
            if let index = args["index"] as? Int, index >= 0, index < (tabManager?.tabs.count ?? 0) {
                tabManager?.closeTab(at: index)
                return "Closed tab at index \(index)"
            }
            tabManager?.closeTab(at: tabManager?.selectedIndex ?? 0)
            return "Closed current tab"

        case "listTabs":
            guard let tabs = tabManager?.tabs else { return "No tabs open" }
            let items = tabs.enumerated().map { i, tab in
                "[\(i)] \(tab.displayTitle) — \(tab.urlString)"
            }
            return items.joined(separator: "\n")

        case "switchTab":
            guard let index = args["index"] as? Int,
                  index >= 0, index < (tabManager?.tabs.count ?? 0) else { return "Invalid tab index" }
            tabManager?.selectTab(at: index)
            return "Switched to tab \(index)"

        // --- Bookmarks ---
        case "addBookmark":
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return "No page to bookmark" }
            let title = (args["title"] as? String) ?? (webView.title ?? url)
            bookmarkStore?.add(title: title, url: url)
            return "Bookmarked: \(title)"

        case "listBookmarks":
            guard let bm = bookmarkStore else { return "No bookmarks" }
            let all = bm.allBookmarks
            guard !all.isEmpty else { return "No bookmarks" }
            return all.map { "\($0.title) — \($0.url)" }.joined(separator: "\n")

        case "removeBookmark":
            guard let url = args["url"] as? String, let bm = bookmarkStore?.find(url: url) else { return "Bookmark not found" }
            bookmarkStore?.remove(bm)
            return "Removed bookmark: \(url)"

        // --- History ---
        case "getHistory":
            let count = args["count"] as? Int ?? 20
            guard let entries = historyStore?.recentEntries(count: count) else { return "No history" }
            guard !entries.isEmpty else { return "No history entries" }
            return entries.map { "\($0.title ?? "Untitled") — \($0.url)" }.joined(separator: "\n")

        case "clearHistory":
            historyStore?.clearAll()
            return "History cleared"

        // --- Page controls ---
        case "findInPage":
            guard let text = args["text"] as? String, !text.isEmpty else { return "Missing search text" }
            return await withCheckedContinuation { continuation in
                let config = WKFindConfiguration()
                webView.find(text, configuration: config) { result in
                    if result.matchFound {
                        continuation.resume(returning: "Found match")
                    } else {
                        continuation.resume(returning: "No matches found")
                    }
                }
            }

        case "toggleDarkMode":
            guard let host = webView.url?.host else { return "No page loaded" }
            guard let sss = siteSettingsStore else { return "Site settings unavailable" }
            let enabled = !sss.darkModeEnabled(for: host)
            sss.setDarkMode(enabled, for: host)
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
            webView.evaluateJavaScript(js, completionHandler: nil)
            return enabled ? "Dark mode enabled" : "Dark mode disabled"

        case "toggleReaderMode":
            let js = """
            (function() {
                var r = document.getElementById('desire-reader');
                if (r) { r.remove(); document.body.style.display = ''; return 'Reader mode disabled'; }
                var text = document.body.innerText;
                if (!text || text.length < 100) return 'Page too short for reader mode';
                var html = '<article><h1>' + (document.title || '') + '</h1>' + text.split('\\\\n').filter(Boolean).map(function(p){ return '<p>' + p + '</p>'; }).join('') + '</article>';
                var s = document.createElement('div');
                s.id = 'desire-reader';
                s.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;z-index:999999;background:#fff;color:#333;overflow:auto;padding:40px 20%;font:18px/1.8 Georgia,serif';
                s.innerHTML = html;
                document.body.appendChild(s);
                return 'Reader mode enabled';
            })();
            """
            return await eval(webView, js)

        case "zoomIn":
            guard let wv = webView as? WKWebView else { return "Zoom failed" }
            let newZoom = min(5.0, max(0.5, wv.pageZoom + 0.1))
            wv.pageZoom = newZoom
            return "Zoomed in to \(Int(newZoom * 100))%"

        case "zoomOut":
            guard let wv = webView as? WKWebView else { return "Zoom failed" }
            let newZoom = min(5.0, max(0.5, wv.pageZoom - 0.1))
            wv.pageZoom = newZoom
            return "Zoomed out to \(Int(newZoom * 100))%"

        case "resetZoom":
            webView.pageZoom = 1.0
            return "Zoom reset to 100%"

        // --- Content blockers ---
        case "toggleAdBlocking":
            guard let cb = contentBlocker else { return "Content blocker not available" }
            let enabled = args["enabled"] as? Bool ?? !cb.isBlockingEnabled
            cb.isBlockingEnabled = enabled
            return enabled ? "Ad blocking enabled" : "Ad blocking disabled"

        case "toggleTrackingProtection":
            guard let cb = contentBlocker else { return "Content blocker not available" }
            let enabled = args["enabled"] as? Bool ?? !cb.isTrackingEnabled
            cb.isTrackingEnabled = enabled
            return enabled ? "Tracking protection enabled" : "Tracking protection disabled"

        // --- Reading list ---
        case "addToReadingList":
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return "No page to add" }
            let title = (args["title"] as? String) ?? (webView.title ?? url)
            readingListStore?.add(title: title, url: url)
            return "Added to reading list: \(title)"

        // --- Downloads ---
        case "listDownloads":
            guard let items = downloadStore?.downloads, !items.isEmpty else { return "No downloads" }
            let active = items.filter { $0.state == .inProgress }
            let completed = items.filter { $0.state == .completed }
            var result: [String] = []
            if !active.isEmpty {
                result.append("Active:")
                result += active.map { "  \($0.filename) — \(Int($0.progress * 100))%" }
            }
            if !completed.isEmpty {
                result.append("Completed:")
                result += completed.map { "  \($0.filename)" }
            }
            return result.joined(separator: "\n")

        // --- Plugins ---
        case "listPlugins":
            guard let plugs = pluginStore?.plugins, !plugs.isEmpty else { return "No plugins installed" }
            return plugs.map { "\($0.isEnabled ? "✅" : "⬜") \($0.name) v\($0.version)" }.joined(separator: "\n")

        case "togglePlugin":
            guard let name = args["name"] as? String,
                  let enabled = args["enabled"] as? Bool,
                  let plugin = pluginStore?.plugins.first(where: { $0.name == name }) else { return "Plugin not found" }
            var updated = plugin
            updated.isEnabled = enabled
            pluginStore?.update(updated)
            return enabled ? "Enabled plugin: \(name)" : "Disabled plugin: \(name)"

        // --- Element blocker ---
        case "listBlockedElements":
            guard let rules = elementBlockStore?.rules, !rules.isEmpty else { return "No blocked elements" }
            return rules.map { "\($0.cssSelector) — \($0.urlPattern)" }.joined(separator: "\n")

        case "unblockElement":
            guard let selector = args["selector"] as? String,
                  let rule = elementBlockStore?.rules.first(where: { $0.cssSelector == selector }) else { return "Rule not found" }
            elementBlockStore?.remove(id: rule.id)
            return "Unblocked: \(selector)"

        // --- Responsive design ---
        case "toggleResponsiveMode":
            guard let tab = tabManager?.selectedTab else { return "No active tab" }
            tab.isResponsiveMode.toggle()
            if let deviceName = args["device"] as? String,
               let preset = devicePresets.first(where: { $0.name.lowercased() == deviceName.lowercased() }) {
                tab.responsiveSize = CGSize(width: CGFloat(preset.width), height: CGFloat(preset.height))
            }
            return tab.isResponsiveMode ? "Responsive mode enabled" : "Responsive mode disabled"

        // --- Picture in Picture ---
        case "togglePictureInPicture":
            return await eval(webView, """
            (function() {
                var v = document.querySelector('video');
                if (!v) return 'No video found';
                if (document.pictureInPictureElement) {
                    document.exitPictureInPicture();
                    return 'Picture-in-picture exited';
                } else if (v.readyState >= 2) {
                    v.requestPictureInPicture();
                    return 'Picture-in-picture started';
                }
                return 'Video not ready';
            })();
            """)

        // --- Tab groups ---
        case "listTabGroups":
            guard let groups = tabGroupStore?.groups, !groups.isEmpty else { return "No tab groups" }
            return groups.map { group in
                let tabNames = group.tabIds.compactMap { tid in tabManager?.tabs.first(where: { $0.id == tid })?.displayTitle }
                return "\(group.name) (\(tabNames.count) tabs)\(tabNames.isEmpty ? "" : ": " + tabNames.joined(separator: ", "))"
            }.joined(separator: "\n")

        case "addTabToGroup":
            guard let tab = tabManager?.selectedTab else { return "No active tab" }
            guard let groupName = args["groupName"] as? String else { return "Missing group name" }
            if let existing = tabGroupStore?.groups.first(where: { $0.name == groupName }) {
                tabGroupStore?.removeTabFromAll(tab.id)
                tabGroupStore?.addTab(tab.id, to: existing.id)
                return "Added to group: \(groupName)"
            }
            let newGroup = tabGroupStore?.create(name: groupName) ?? TabGroup(id: UUID(), name: groupName, colorIndex: 0, tabIds: [])
            tabGroupStore?.removeTabFromAll(tab.id)
            tabGroupStore?.addTab(tab.id, to: newGroup.id)
            return "Created and added to group: \(groupName)"

        case "removeTabFromGroup":
            guard let tab = tabManager?.selectedTab else { return "No active tab" }
            tabGroupStore?.removeTabFromAll(tab.id)
            return "Removed from tab group"

        // --- Print & PDF ---
        case "printPage":
            let printInfo = NSPrintInfo.shared
            printInfo.horizontalPagination = .fit
            printInfo.verticalPagination = .fit
            let operation = webView.printOperation(with: printInfo)
            operation.run()
            return "Print dialog opened"

        case "saveAsPDF":
            return await withCheckedContinuation { continuation in
                let config = WKPDFConfiguration()
                webView.createPDF(configuration: config) { result in
                    switch result {
                    case .success(let data):
                        let panel = NSSavePanel()
                        panel.title = String(localized: "Save as PDF")
                        panel.nameFieldStringValue = "\(webView.title ?? "page").pdf"
                        panel.allowedContentTypes = [.pdf]
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                try? data.write(to: url)
                                continuation.resume(returning: "PDF saved to \(url.lastPathComponent)")
                            } else {
                                continuation.resume(returning: "PDF save cancelled")
                            }
                        }
                    case .failure(let error):
                        continuation.resume(returning: "Error creating PDF: \(error.localizedDescription)")
                    }
                }
            }

        // --- Quick Dials ---
        case "listQuickDials":
            guard let dials = quickDialStore?.dials, !dials.isEmpty else { return "No quick dials" }
            return dials.map { "\($0.title) — \($0.url)" }.joined(separator: "\n")

        case "addQuickDial":
            guard let title = args["title"] as? String, let url = args["url"] as? String else { return "Missing title or url" }
            quickDialStore?.add(title: title, url: url)
            return "Added quick dial: \(title)"

        case "removeQuickDial":
            guard let title = args["title"] as? String,
                  let dial = quickDialStore?.dials.first(where: { $0.title == title }) else { return "Quick dial not found" }
            quickDialStore?.delete(id: dial.id)
            return "Removed quick dial: \(title)"

        // --- Search engine ---
        case "setSearchEngine":
            guard let name = args["engine"] as? String,
                  let engine = SearchEngine.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                let options = SearchEngine.allCases.map(\.rawValue).joined(separator: ", ")
                return "Invalid engine. Options: \(options)"
            }
            settings?.searchEngine = engine
            return "Search engine changed to \(engine.rawValue)"

        // --- Sidebar ---
        case "toggleSidebar":
            NotificationCenter.default.post(name: .browserCommand, object: BrowserCommand.toggleSidebar)
            return "Sidebar toggled"

        // --- DOM interaction (existing) ---
        case "click":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await eval(webView, """
            (function() {
                var el = document.querySelector('\(sel.jsEscaped)');
                if (!el) return 'Element not found: \(sel.jsEscaped)';
                el.click();
                return 'Clicked';
            })()
            """)

        case "fill":
            guard let sel = args["selector"] as? String, let val = args["value"] as? String else { return "Missing selector or value" }
            return await eval(webView, """
            (function() {
                var el = document.querySelector('\(sel.jsEscaped)');
                if (!el) return 'Element not found';
                el.value = '\(val.jsEscaped)';
                el.dispatchEvent(new Event('input', {bubbles:true}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
                return 'Filled';
            })()
            """)

        case "select":
            guard let sel = args["selector"] as? String, let val = args["value"] as? String else { return "Missing selector or value" }
            return await eval(webView, """
            (function() {
                var el = document.querySelector('\(sel.jsEscaped)');
                if (!el) return 'Element not found';
                el.value = '\(val.jsEscaped)';
                el.dispatchEvent(new Event('change', {bubbles:true}));
                return 'Selected';
            })()
            """)

        case "scroll":
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            return await eval(webView, "window.scrollTo(\(x), \(y)); 'Scrolled'")

        case "hover":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await eval(webView, """
            (function() {
                var el = document.querySelector('\(sel.jsEscaped)');
                if (!el) return 'Element not found';
                el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
                return 'Hovered';
            })()
            """)

        case "focus":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await eval(webView, """
            (function() {
                var el = document.querySelector('\(sel.jsEscaped)');
                if (!el) return 'Element not found';
                el.focus();
                return 'Focused';
            })()
            """)

        case "extract":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await eval(webView, """
            (function() {
                var els = document.querySelectorAll('\(sel.jsEscaped)');
                return Array.from(els).map(function(e){ return e.textContent.trim(); }).filter(Boolean).join('\\n---\\n');
            })()
            """)

        case "findElements":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await eval(webView, """
            (function() {
                var els = document.querySelectorAll('\(sel.jsEscaped)');
                if (els.length === 0) return 'No elements found';
                var first = els[0].textContent.trim().substring(0, 200);
                return 'Found ' + els.length + ' elements. First: ' + first;
            })()
            """)

        // --- Utilities ---
        case "wait":
            let ms = args["ms"] as? Int ?? 1000
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "Waited \(ms)ms"

        case "waitForElement":
            let sel = args["selector"] as? String ?? ""
            let timeout = args["timeout"] as? Int ?? 5000
            return await eval(webView, """
            (function() {
                var start = Date.now();
                return new Promise(function(resolve) {
                    function check() {
                        var el = document.querySelector('\(sel.jsEscaped)');
                        if (el) return resolve('Found element');
                        if (Date.now() - start > \(timeout)) return resolve('Timeout');
                        setTimeout(check, 200);
                    }
                    check();
                });
            })()
            """)

        case "executeJS":
            guard let code = args["code"] as? String else { return "Missing code" }
            return await eval(webView, code) ?? "Executed (no return value)"

        default:
            return "Unknown tool: \(call.function.name)"
        }
    }

    // MARK: - Helpers

    private func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url == "about:blank" || url.hasPrefix("desire://newtab")
    }

    private func eval(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { continuation in
            wv.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else if let result = result {
                    continuation.resume(returning: "\(result)")
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func captureScreenshot(_ wv: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let image = image,
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let b64 = png.base64EncodedString()
                        continuation.resume(returning: b64)
                    } else {
                        continuation.resume(returning: "Error: PNG encoding failed")
                    }
                } else {
                    continuation.resume(returning: "Error: failed to capture screenshot")
                }
            }
        }
    }
}

private extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
