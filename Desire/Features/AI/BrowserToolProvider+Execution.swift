import AppKit
import UniformTypeIdentifiers
import WebKit

/// Tool dispatcher: resolves a single tool call against the `surface`.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + small helpers. The `surface` is guarded at the top of `execute`.
extension BrowserToolProvider {
    func execute(_ call: AIToolCall, in webView: WKWebView) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
        // Tools resolve their store targets through the surface. If it isn't
        // attached yet, only the pure-webview tools (which don't touch a
        // store) would work — fail fast for the rest with a clear message.
        guard let surface else {
            return "Tool surface not configured"
        }
        switch call.function.name {
        // --- Page reading ---
        case "getPageSnapshot":
            let maxChars = args["maxChars"] as? Int ?? 12000
            let maxElements = args["maxElements"] as? Int ?? 60
            return await callAsync(webView, function: "__desireSnapshot",
                                   args: ["maxChars": maxChars, "maxElements": maxElements])
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
            let jsEnabled = surface.settings.isJavaScriptEnabled
            var containerID: UUID?
            var containerNote = ""
            if let containerName = args["container"] as? String, !containerName.isEmpty {
                guard let container = ContainerStore.shared.containers.first(where: {
                    $0.name.lowercased() == containerName.lowercased()
                }) else {
                    let names = ContainerStore.shared.containers.map(\.name).joined(separator: ", ")
                    return "Container not found: \(containerName). Available: \(names.isEmpty ? "(none)" : names)"
                }
                containerID = container.id
                containerNote = " in container \(container.name)"
            }
            surface.tabManager?.addTab(url: url, javaScriptEnabled: jsEnabled, contentBlocker: surface.contentBlocker, videoAdBlocker: surface.videoAdBlocker, containerID: containerID)
            return (url.map { "Opened new tab with \($0)" } ?? "Opened new tab") + containerNote

        case "listContainers":
            let containers = ContainerStore.shared.containers
            guard !containers.isEmpty else { return "No containers configured" }
            return containers.map { "\($0.name) (\($0.colorName))" }.joined(separator: "\n")

        case "closeTab":
            if let index = args["index"] as? Int, index >= 0, index < (surface.tabManager?.tabs.count ?? 0) {
                surface.tabManager?.closeTab(at: index)
                return "Closed tab at index \(index)"
            }
            surface.tabManager?.closeTab(at: surface.tabManager?.selectedIndex ?? 0)
            return "Closed current tab"

        case "listTabs":
            guard let tabs = surface.tabManager?.tabs else { return "No tabs open" }
            let items = tabs.enumerated().map { i, tab in
                "[\(i)] \(tab.displayTitle) — \(tab.urlString)"
            }
            return items.joined(separator: "\n")

        case "switchTab":
            guard let index = args["index"] as? Int,
                  index >= 0, index < (surface.tabManager?.tabs.count ?? 0) else { return "Invalid tab index" }
            surface.tabManager?.selectTab(at: index)
            return "Switched to tab \(index)"

        // --- Bookmarks ---
        case "addBookmark":
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return "No page to bookmark" }
            let title = (args["title"] as? String) ?? (webView.title ?? url)
            surface.bookmarkStore.add(title: title, url: url)
            return "Bookmarked: \(title)"

        case "listBookmarks":
            let all = surface.bookmarkStore.allBookmarks
            guard !all.isEmpty else { return "No bookmarks" }
            return all.map { "\($0.title) — \($0.url ?? "[folder]")" }.joined(separator: "\n")

        case "removeBookmark":
            guard let url = args["url"] as? String, let bm = surface.bookmarkStore.find(url: url) else { return "Bookmark not found" }
            surface.bookmarkStore.remove(bm)
            return "Removed bookmark: \(url)"

        // --- History ---
        case "getHistory":
            let count = args["count"] as? Int ?? 20
            let entries = surface.historyStore.recentEntries(count: count)
            guard !entries.isEmpty else { return "No history entries" }
            return entries.map { "\($0.title) — \($0.url)" }.joined(separator: "\n")

        case "clearHistory":
            surface.historyStore.clearAll()
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
            let enabled = !surface.siteSettingsStore.darkModeEnabled(for: host)
            surface.siteSettingsStore.setDarkMode(enabled, for: host)
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
            _ = try? await webView.evaluateJavaScript(js)
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
            let newZoom = min(5.0, max(0.5, webView.pageZoom + 0.1))
            webView.pageZoom = newZoom
            return "Zoomed in to \(Int(newZoom * 100))%"

        case "zoomOut":
            let newZoom = min(5.0, max(0.5, webView.pageZoom - 0.1))
            webView.pageZoom = newZoom
            return "Zoomed out to \(Int(newZoom * 100))%"

        case "resetZoom":
            webView.pageZoom = 1.0
            return "Zoom reset to 100%"

        // --- Content blockers ---
        case "toggleAdBlocking":
            let enabled = args["enabled"] as? Bool ?? !surface.contentBlocker.isBlockingEnabled
            surface.contentBlocker.isBlockingEnabled = enabled
            return enabled ? "Ad blocking enabled" : "Ad blocking disabled"

        case "toggleTrackingProtection":
            let enabled = args["enabled"] as? Bool ?? !surface.contentBlocker.isTrackingEnabled
            surface.contentBlocker.isTrackingEnabled = enabled
            return enabled ? "Tracking protection enabled" : "Tracking protection disabled"

        // --- Reading list ---
        case "addToReadingList":
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return "No page to add" }
            let title = (args["title"] as? String) ?? (webView.title ?? url)
            surface.readingListStore.add(title: title, url: url)
            return "Added to reading list: \(title)"

        // --- Downloads ---
        case "listDownloads":
            let items = surface.downloadStore.downloads
            guard !items.isEmpty else { return "No downloads" }
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
            let plugs = surface.pluginStore.plugins
            guard !plugs.isEmpty else { return "No plugins installed" }
            return plugs.map { "\($0.isEnabled ? "✅" : "⬜") \($0.name) v\($0.version)" }.joined(separator: "\n")

        case "togglePlugin":
            guard let name = args["name"] as? String,
                  let enabled = args["enabled"] as? Bool,
                  let plugin = surface.pluginStore.plugins.first(where: { $0.name == name }) else { return "Plugin not found" }
            var updated = plugin
            updated.isEnabled = enabled
            surface.pluginStore.update(updated)
            return enabled ? "Enabled plugin: \(name)" : "Disabled plugin: \(name)"

        // --- Element blocker ---
        case "listBlockedElements":
            let rules = surface.elementBlockStore.rules
            guard !rules.isEmpty else { return "No blocked elements" }
            return rules.map { "\($0.cssSelector) — \($0.urlPattern)" }.joined(separator: "\n")

        case "unblockElement":
            guard let selector = args["selector"] as? String,
                  let rule = surface.elementBlockStore.rules.first(where: { $0.cssSelector == selector }) else { return "Rule not found" }
            surface.elementBlockStore.remove(id: rule.id)
            return "Unblocked: \(selector)"

        // --- Responsive design ---
        case "toggleResponsiveMode":
            guard let tab = surface.tabManager?.selectedTab else { return "No active tab" }
            tab.responsiveConfig.isEnabled.toggle()
            if let deviceName = args["device"] as? String,
               let preset = devicePresets.first(where: { $0.name.lowercased() == deviceName.lowercased() }) {
                tab.responsiveConfig.selectedPresetID = preset.id
                tab.responsiveConfig.customWidth = preset.width
                tab.responsiveConfig.customHeight = preset.height
            }
            return tab.responsiveConfig.isEnabled ? "Responsive mode enabled" : "Responsive mode disabled"

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
            let groups = surface.tabGroupStore.groups
            guard !groups.isEmpty else { return "No tab groups" }
            return groups.map { group in
                let tabNames = group.tabIds.compactMap { tid in surface.tabManager?.tabs.first(where: { $0.id == tid })?.displayTitle }
                return "\(group.name) (\(tabNames.count) tabs)\(tabNames.isEmpty ? "" : ": " + tabNames.joined(separator: ", "))"
            }.joined(separator: "\n")

        case "addTabToGroup":
            guard let tab = surface.tabManager?.selectedTab else { return "No active tab" }
            guard let groupName = args["groupName"] as? String else { return "Missing group name" }
            if let existing = surface.tabGroupStore.groups.first(where: { $0.name == groupName }) {
                surface.tabGroupStore.removeTabFromAll(tab.id)
                surface.tabGroupStore.addTab(tab.id, to: existing.id)
                return "Added to group: \(groupName)"
            }
            let newGroup = surface.tabGroupStore.create(name: groupName)
            surface.tabGroupStore.removeTabFromAll(tab.id)
            surface.tabGroupStore.addTab(tab.id, to: newGroup.id)
            return "Created and added to group: \(groupName)"

        case "removeTabFromGroup":
            guard let tab = surface.tabManager?.selectedTab else { return "No active tab" }
            surface.tabGroupStore.removeTabFromAll(tab.id)
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
            let dials = surface.quickDialStore.dials
            guard !dials.isEmpty else { return "No quick dials" }
            return dials.map { "\($0.title) — \($0.url)" }.joined(separator: "\n")

        case "addQuickDial":
            guard let title = args["title"] as? String, let url = args["url"] as? String else { return "Missing title or url" }
            surface.quickDialStore.add(title: title, url: url)
            return "Added quick dial: \(title)"

        case "removeQuickDial":
            guard let title = args["title"] as? String,
                  let dial = surface.quickDialStore.dials.first(where: { $0.title == title }) else { return "Quick dial not found" }
            surface.quickDialStore.delete(id: dial.id)
            return "Removed quick dial: \(title)"

        // --- Search engine ---
        case "setSearchEngine":
            guard let name = args["engine"] as? String else { return "Missing engine name" }
            // Built-ins first, then custom engines by (case-insensitive) name.
            if let engine = SearchEngine.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                surface.settings.searchEngine = engine
                // A stale custom pick would keep winning the effective
                // engine regardless of the built-in set here.
                surface.settings.selectedCustomEngineId = nil
                return "Search engine changed to \(engine.rawValue)"
            }
            if let custom = surface.settings.customEngines.first(where: { $0.name.lowercased() == name.lowercased() }) {
                surface.settings.selectedCustomEngineId = custom.id
                return "Search engine changed to custom engine \(custom.name)"
            }
            let options = (SearchEngine.allCases.map(\.rawValue) + surface.settings.customEngines.map(\.name)).joined(separator: ", ")
            return "Invalid engine. Options: \(options)"

        // --- Sidebar ---
        case "toggleSidebar":
            CommandBus.shared.send(.toggleSidebar)
            return "Sidebar toggled"

        // --- DOM interaction ---
        // These tools invoke page-world functions (UserScripts/dom-tools.js)
        // via callAsyncJavaScript, passing parameters as native values.
        // NO string interpolation: model-controlled selectors/values cannot
        // break out into code. See docs/ARCHITECTURE.md (L2 JS Bridge).
        case "click":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            // Prefer a real (isTrusted=true) mouse click through the AppKit
            // event pipeline — untrusted `element.click()` is a bot signal
            // for anti-automation systems (Turnstile) and can get the user's
            // session challenged. The JS fallback keeps the tool working
            // when the webview has no window (suspended/background tab) or
            // the element resolves to no on-screen geometry.
            if let point = await clickablePoint(selector: sel, in: webView) {
                await SyntheticInput.click(at: point, in: webView)
                return "Clicked (trusted mouse event)"
            }
            return await callAsync(webView, function: "__desireClick", args: ["selector": sel])

        case "clickAt":
            // Vision-loop primitive: pairs with the screenshot tool. x/y are
            // CSS pixels of the viewport (the coordinate space getPageSnapshot
            // reports), dispatched as a REAL mouse event.
            guard let x = args["x"] as? Double, let y = args["y"] as? Double else {
                return "Missing x or y (viewport CSS pixels)"
            }
            guard webView.window != nil else {
                return "No window attached — coordinate clicks need a visible webview"
            }
            let point = windowPoint(fromViewportX: x, y: y, in: webView)
            await SyntheticInput.click(at: point, in: webView)
            return "Clicked at (\(Int(x)), \(Int(y)))"

        case "fill":
            guard let sel = args["selector"] as? String, let val = args["value"] as? String else { return "Missing selector or value" }
            return await callAsync(webView, function: "__desireFill", args: ["selector": sel, "value": val])

        case "select":
            guard let sel = args["selector"] as? String, let val = args["value"] as? String else { return "Missing selector or value" }
            return await callAsync(webView, function: "__desireSelect", args: ["selector": sel, "value": val])

        case "scroll":
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            return await callAsync(webView, function: "__desireScroll", args: ["x": x, "y": y])

        case "hover":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            // Trusted mouse-moved stream, same rationale as `click`.
            if let point = await clickablePoint(selector: sel, in: webView) {
                await SyntheticInput.hover(at: point, in: webView)
                return "Hovered (trusted mouse events)"
            }
            return await callAsync(webView, function: "__desireHover", args: ["selector": sel])

        case "focus":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await callAsync(webView, function: "__desireFocus", args: ["selector": sel])

        case "extract":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await callAsync(webView, function: "__desireExtract", args: ["selector": sel])

        case "findElements":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await callAsync(webView, function: "__desireFindElements", args: ["selector": sel])

        // --- Utilities ---
        case "wait":
            let ms = args["ms"] as? Int ?? 1000
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "Waited \(ms)ms"

        case "waitForElement":
            let sel = args["selector"] as? String ?? ""
            let timeout = args["timeout"] as? Int ?? 5000
            return await callAsync(webView, function: "__desireWaitForElement", args: ["selector": sel, "timeout": timeout])

        case "executeJS":
            guard let code = args["code"] as? String else { return "Missing code" }
            let result = await eval(webView, code)
            return result.isEmpty ? "Executed (no return value)" : result

        default:
            return "Unknown tool: \(call.function.name)"
        }
    }

    /// Resolves `selector` to its center point in window-base coordinates
    /// (what `NSEvent.mouseEvent(location:)` expects) after scrolling the
    /// element into view. Returns nil when the webview has no window, the
    /// element is missing, or it has no on-screen geometry — callers then
    /// fall back to the in-page JS path.
    private func clickablePoint(selector: String, in webView: WKWebView) async -> CGPoint? {
        guard webView.window != nil else { return nil }
        let raw = await callAsync(webView, function: "__desireElementRect", args: ["selector": selector])
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = obj["x"], let y = obj["y"],
              let w = obj["w"], let h = obj["h"], w > 0, h > 0 else { return nil }

        // The JS rect is CSS px, top-left origin; the NSView pipeline wants
        // view/base-window px, bottom-left origin. pageZoom scales CSS px
        // into view px; `isFlipped` covers whichever orientation WKWebView
        // reports.
        return windowPoint(fromViewportX: x + w / 2, y: y + h / 2, in: webView)
    }

    /// Converts a viewport CSS-pixel point (the coordinate space of
    /// `getBoundingClientRect` and screenshots) into window-base coordinates
    /// for synthetic event dispatch. Accounts for page zoom and view flip.
    private func windowPoint(fromViewportX x: Double, y: Double, in webView: WKWebView) -> CGPoint {
        let zoom = CGFloat(webView.pageZoom)
        let viewPoint = CGPoint(x: CGFloat(x) * zoom, y: CGFloat(y) * zoom)
        let cocoaPoint = webView.isFlipped
            ? viewPoint
            : CGPoint(x: viewPoint.x, y: webView.bounds.height - viewPoint.y)
        return webView.convert(cocoaPoint, to: nil)
    }
}
