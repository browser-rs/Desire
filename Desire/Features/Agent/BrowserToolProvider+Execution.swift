import AppKit
import UniformTypeIdentifiers
import WebKit

/// Tool dispatcher: resolves a single tool call against the `surface`.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + small helpers. The `surface` is guarded at the top of `execute`.
extension BrowserToolProvider {
    func execute(_ call: AgentToolCall, in webView: WKWebView) async -> String {
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
        case "readTab":
            // Cross-tab perception: snapshot another tab's page without
            // switching. Suspended tabs are blanked webviews — say so
            // instead of returning an empty snapshot.
            guard let index = args["index"] as? Int,
                  let tabs = surface.tabManager?.tabs,
                  tabs.indices.contains(index) else {
                return "Invalid tab index (use listTabs)"
            }
            let target = tabs[index]
            guard !target.isSuspended else {
                return "Tab \(index) is suspended — switchTab to it first, then readTab"
            }
            let snapshot = await callAsync(target.browser.webView, function: "__desireSnapshot",
                                           args: ["maxChars": 6000, "maxElements": 25])
            return "[\(target.displayTitle) — \(target.browser.webView.url?.host ?? "")]\n\(snapshot)"

        case "getPageText":
            return await eval(webView, "document.body.innerText")
        case "getComments":
            // Structured comment-section extraction (author/text/time/likes)
            // for "总结评论" and reply drafting. Site-agnostic heuristics.
            let maxItems = args["maxItems"] as? Int ?? 50
            let raw = await callAsync(webView, function: "__desireGetComments",
                                      args: ["maxItems": maxItems])
            return raw.isEmpty ? "No comment section detected on this page" : raw
        case "getConversation":
            // Web-chat (IM) message extraction for "总结对话" and reply
            // drafting. Site-agnostic heuristics.
            let maxItems = args["maxItems"] as? Int ?? 100
            let raw = await callAsync(webView, function: "__desireGetConversation",
                                      args: ["maxItems": maxItems])
            return raw.isEmpty ? "No chat conversation detected on this page" : raw
        case "getPageHTML":
            return await eval(webView, "document.documentElement.outerHTML")
        case "getPageTitle":
            return await eval(webView, "document.title")
        case "screenshot":
            return await captureScreenshot(webView)
        case "screenshotElement":
            // Close-up vision capture of ONE element (charts, icon grids,
            // embedded widgets) — sharper than a full-viewport screenshot.
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return "Provide one of: ref, text, or selector"
            }
            guard let rectData = await callAsync(webView, function: "__desireElementRect",
                    args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""]).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: rectData)) as? [String: Double],
                  let x = obj["x"], let y = obj["y"],
                  let w = obj["w"], let h = obj["h"], w > 1, h > 1 else {
                return "Element not found"
            }
            // getBoundingClientRect is viewport CSS px; the snapshot rect is
            // view coordinates — pageZoom scales between them. Clamp to the
            // visible viewport.
            let zoom = CGFloat(webView.pageZoom)
            let bounds = webView.bounds.size
            let rect = CGRect(
                x: max(0, CGFloat(x) * zoom),
                y: max(0, CGFloat(y) * zoom),
                width: min(CGFloat(w) * zoom, bounds.width),
                height: min(CGFloat(h) * zoom, bounds.height)
            )
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = rect
            snapConfig.afterScreenUpdates = true
            do {
                let image = try await webView.takeSnapshot(configuration: snapConfig)
                guard let uri = ImageAttachment.dataURI(from: image) else {
                    return "Capture failed"
                }
                return uri
            } catch {
                return "Capture failed: \(error.localizedDescription)"
            }

        case "getTables":
            return await callAsync(webView, function: "__desireGetTables",
                                   args: ["maxTables": args["maxTables"] as? Int ?? 5])
        case "getImages":
            return await callAsync(webView, function: "__desireGetImages",
                                   args: ["maxItems": args["maxItems"] as? Int ?? 40])
        case "getPageMeta":
            return await callAsync(webView, function: "__desireGetPageMeta", args: [:])
        case "getElementHTML":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else { return "Provide ref, text, or selector" }
            return await callAsync(webView, function: "__desireGetElementHTML",
                                   args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? "",
                                          "maxLength": args["maxLength"] as? Int ?? 6000])
        case "getNetworkLog":
            let filter = args["filter"] as? String ?? ""
            return await callAsync(webView, function: "__desireGetNetworkLog",
                                   args: ["filter": filter, "maxItems": args["maxItems"] as? Int ?? 100])

        case "getSelectedText":
            return await eval(webView, "window.getSelection().toString()")

        // --- Navigation ---
        case "navigate":
            guard let url = args["url"] as? String, let u = URL(string: url) else { return "Invalid URL" }
            // Mirror BrowsingActions.navigateToURL's state sync. `load` alone
            // is invisible when the tab sits on an overlay: isOnNewTabPage
            // is STORED state (the NewTabPage keeps covering the webview),
            // and an unmounted webview has no navigation delegate to update
            // urlString — so the DOM loads, snapshots read real content, and
            // the user still sees the new-tab page.
            if let tab = surface.tabManager?.tabs.first(where: { $0.browser.webView === webView }) {
                tab.isOnNewTabPage = false
                tab.isSuspended = false
                tab.urlString = u.absoluteString
            }
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

        case "closeOtherTabs":
            // Keep the selected tab, close the rest of THIS window.
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return "No tabs open" }
            let keep = manager.selectedIndex
            let before = manager.tabs.count
            manager.closeOthers(keeping: keep)
            return "Closed \(before - manager.tabs.count) other tabs"

        case "reopenLastClosedTab":
            guard let manager = surface.tabManager else { return "No window" }
            let reopened = manager.reopenLastClosedTab(
                javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker
            )
            return reopened ? "Reopened last closed tab" : "No recently closed tab"

        case "duplicateTab":
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return "No tabs open" }
            manager.duplicateTab(
                at: manager.selectedIndex,
                javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker
            )
            return "Duplicated current tab"

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
        //
        // Targeting modes, resolved in-page in this order: ref (snapshot
        // id) > text (visible label) > CSS selector.
        case "click":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return "Provide one of: ref (from getPageSnapshot), text (visible label), or selector"
            }
            // Prefer a real (isTrusted=true) mouse click through the AppKit
            // event pipeline — untrusted `element.click()` is a bot signal
            // for anti-automation systems (Turnstile) and can get the user's
            // session challenged. The JS fallback keeps the tool working
            // when the webview has no window (suspended/background tab) or
            // the element resolves to no on-screen geometry.
            if let point = await clickablePoint(selector: sel, ref: ref, text: text, in: webView) {
                await SyntheticInput.click(at: point, in: webView)
                return "Clicked (trusted mouse event)"
            }
            return await callAsync(webView, function: "__desireClick",
                                   args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])

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

        case "highlight":
            // Agent visibility: scroll to the element and flash an orange
            // outline so the user can SEE what is about to be acted on.
            // Pairs naturally before click/fill in narrated tasks.
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return "Provide one of: ref, text, or selector"
            }
            let result = await callAsync(webView, function: "__desireHighlight",
                                         args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])
            return result.isEmpty ? "Element not found" : result

        case "getPageLinks":
            // Navigation planning: the page's visible links as {text, href}.
            let maxItems = args["maxItems"] as? Int ?? 50
            return await callAsync(webView, function: "__desireGetLinks",
                                   args: ["maxItems": maxItems])

        case "listPageVideos":
            // Merge two detection paths: the network sniffer (real CDN URLs
            // behind blob: players, accumulated in the owning tab's
            // BrowserState) and the on-demand DOM/meta scan.
            let sniffed = surface.tabManager?.tabs
                .first(where: { $0.browser.webView === webView })?
                .browser.detectedMedia ?? []
            let scan = await callAsync(webView, function: "__desireScanMedia", args: [:])
            var scanned: [(url: String, kind: String, mime: String, source: String, isBlob: Bool)] = []
            if let data = scan.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let items = obj["items"] as? [[String: Any]] {
                for item in items {
                    guard let url = item["url"] as? String else { continue }
                    scanned.append((
                        url,
                        item["kind"] as? String ?? "video",
                        item["mime"] as? String ?? "",
                        item["source"] as? String ?? "dom",
                        item["isBlob"] as? Bool ?? false
                    ))
                }
            }

            var lines: [String] = []
            var seen = Set<String>()
            for entry in sniffed where !seen.contains(entry.url) {
                seen.insert(entry.url)
                var line = "[\(entry.kind.rawValue)] \(entry.url)"
                var meta: [String] = []
                if !entry.mime.isEmpty { meta.append("type: \(entry.mime)") }
                if let size = entry.displaySize { meta.append(size) }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                lines.append(line)
            }
            for entry in scanned where !seen.contains(entry.url) {
                seen.insert(entry.url)
                var line = "[\(entry.kind)] \(entry.url)"
                if entry.isBlob { line += " (blob: only usable inside the page — look for the stream/mp4 entries instead)" }
                else { line += " (via \(entry.source))" }
                lines.append(line)
            }

            if lines.isEmpty {
                return "No video/audio resources detected on this page. Try playing the video first — the network sniffer records the stream as it loads."
            }
            return "\(lines.count) media resource(s):\n" + lines.joined(separator: "\n")

        case "downloadMedia":
            // Export a media resource to ~/Downloads. Direct files stream to
            // disk; HLS playlists (m3u8) are parsed, their segments fetched
            // (with the page URL as Referer + the webview's Safari UA against
            // hotlink protection), decrypted when AES-128, and concatenated
            // into one playable file. Blocks this tool call until finished —
            // progress lands in the result.
            guard let urlString = args["url"] as? String, let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else {
                return "Invalid url (http/https only)"
            }
            let hint = args["fileName"] as? String
            do {
                let result = try await MediaExporter.download(
                    url: url,
                    referer: webView.url,
                    userAgent: webView.customUserAgent,
                    fileNameHint: hint
                ) { _, _ in
                    // Per-segment progress hook (no UI sink yet — the tool
                    // call itself surfaces as currentAction in the panel).
                }
                var report = "Saved to ~/Downloads/\(result.fileURL.lastPathComponent) — \(result.segmentCount) segment(s), \(result.displayBytes)"
                result.warnings.forEach { report += "\n⚠️ \($0)" }
                return report
            } catch is CancellationError {
                return "[Cancelled by user]"
            } catch let error as URLError where error.code == .cancelled {
                return "[Cancelled by user]"
            } catch {
                return "Download failed: \(error.localizedDescription)"
            }

        case "updatePlan":
            // Visible task checklist: the model maintains the step list and
            // the panel renders it live (Claude-TodoWrite style).
            guard let items = args["steps"] as? [[String: Any]] else {
                return "Missing steps array"
            }
            var steps: [AgentPlanStep] = []
            for item in items.prefix(12) {
                guard let content = item["content"] as? String, !content.isEmpty else { continue }
                var status = item["status"] as? String ?? "pending"
                if !["pending", "in_progress", "done"].contains(status) { status = "pending" }
                steps.append(AgentPlanStep(content: String(content.prefix(120)), status: status))
            }
            guard !steps.isEmpty else { return "No valid steps" }
            AgentPlanStore.shared.set(steps)
            let done = steps.filter { $0.status == "done" }.count
            return "Plan updated: \(done)/\(steps.count) done"

        case "setUploadFile":
            // Arms a local file so the NEXT page file-picker auto-submits
            // it (the open panel is intercepted in the UI delegate). This
            // is the upload primitive behind platform publishing skills.
            if args["clear"] as? Bool == true {
                UploadIntent.shared.arm([])
                return "Upload intent cleared"
            }
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
                return "Missing path (or clear=true to disarm)"
            }
            let expanded = (rawPath as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return "File not found: \(fileURL.path)"
            }
            UploadIntent.shared.arm([fileURL])
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
            let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return "Armed '\(fileURL.lastPathComponent)'\(sizeText.isEmpty ? "" : " (\(sizeText))"). Clicking the page's upload button now auto-submits it (consumed once)."

        case "renderDiagram":
            // Built-in canvas: render Mermaid (mindmap/flowchart/sequence/…)
            // on a canvas page served by the preview server.
            guard let source = args["source"] as? String, !source.isEmpty else { return "Missing source (Mermaid syntax)" }
            let title = args["title"] as? String ?? "Diagram"
            let safeSource = source.replacingOccurrences(of: "</script>", with: "<\\/script>")
            let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;")
            let safeFile = title.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "/", with: "-")
            let page = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(safeTitle)</title>
            <style>
              body{font-family:-apple-system,sans-serif;margin:20px}
              #bar{display:flex;gap:6px;margin-bottom:12px}
              #bar button{font:12px -apple-system;padding:4px 10px;border-radius:6px;
                border:1px solid #ccc;background:#fff;cursor:pointer}
              .mermaid{transform-origin:top left;display:inline-block;min-width:100%}
              .error{color:#c00;font-family:monospace;white-space:pre-wrap}
            </style></head>
            <body>
            <div id="bar">
              <button onclick="zoom(-0.1)">−</button>
              <button onclick="zoom(0.1)">＋</button>
              <button onclick="resetZoom()">1:1</button>
              <button onclick="exportSVG()">导出 SVG</button>
              <button onclick="exportPNG()">导出 PNG</button>
            </div>
            <h1>\(safeTitle)</h1>
            <pre class="mermaid">\(safeSource)</pre>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <script>
            const dark = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches;
            if (dark) document.body.style.background = '#1e1e1e';
            let scale = 1;
            function applyScale(){ const el = document.querySelector('.mermaid');
              el.style.transform = 'scale(' + scale + ')'; el.style.transformOrigin = 'top left'; }
            function zoom(d){ scale = Math.min(4, Math.max(0.2, scale + d)); applyScale(); }
            function resetZoom(){ scale = 1; applyScale(); }
            function svgNode(){ return document.querySelector('.mermaid svg'); }
            function exportSVG(){ const svg = svgNode(); if (!svg) return alert('尚未渲染完成');
              const blob = new Blob([svg.outerHTML], {type:'image/svg+xml'});
              const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
              a.download = '\(safeFile).svg'; a.click(); }
            function exportPNG(){ const svg = svgNode(); if (!svg) return alert('尚未渲染完成');
              const xml = new XMLSerializer().serializeToString(svg);
              const img = new Image();
              img.onload = function(){ const w = svg.viewBox.baseVal.width || 1000;
                const h = svg.viewBox.baseVal.height || 600;
                const c = document.createElement('canvas'); c.width = w; c.height = h;
                const ctx = c.getContext('2d'); ctx.fillStyle = '#fff';
                ctx.fillRect(0,0,w,h); ctx.drawImage(img,0,0,w,h);
                const a = document.createElement('a'); a.href = c.toDataURL('image/png');
                a.download = '\(safeFile).png'; a.click(); };
              img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml); }
            mermaid.initialize({ startOnLoad:true, theme: dark ? 'dark' : 'default' });
            mermaid.run({ querySelector:'.mermaid' }).then(applyScale).catch(function(e){
              document.body.insertAdjacentHTML('beforeend',
                '<p class="error">渲染失败：'+e.message+'</p><pre class="error">'+
                document.querySelector('.mermaid').textContent+'</pre>'); });
            </script></body></html>
            """
            let dir = AgentWorkspace.shared.directory.appendingPathComponent("canvas", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileName = "canvas/diagram-\(Int(Date().timeIntervalSince1970)).html"
            let fileURL = AgentWorkspace.shared.directory.appendingPathComponent(fileName)
            try? page.write(to: fileURL, atomically: true, encoding: .utf8)
            let base = PreviewServer.ensureRunning()
            let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            let url = base.appendingPathComponent(encoded)
            webView.load(URLRequest(url: url))
            return "Diagram rendered at \(url.absoluteString) (Mermaid syntax — edit the file at \(fileURL.path) to iterate)"

        case "askUser":
            // Mid-task clarification: pauses the loop until the user answers
            // in the panel. The question card IS the interaction (readonly).
            guard let question = args["question"] as? String, !question.isEmpty else {
                return "Missing question"
            }
            let answer = await UserPromptCenter.shared.ask(question)
            return answer

        case "writeFile":
            // Save agent-produced content to a local file. Restricted to the
            // user's folders (Downloads/Documents/Desktop) + app support.
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else { return "Missing path" }
            let content = args["content"] as? String ?? ""
            switch AgentWorkspace.shared.resolve(rawPath, write: true) {
            case .denied(let reason):
                return reason
            case .granted(let fileURL):
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                    return "Wrote \(content.count) chars → \(fileURL.path)"
                } catch {
                    return "Write failed: \(error.localizedDescription)"
                }
            }

        case "readFile":
            // Text file read from the workspace / user folders. Binary
            // files are reported instead of dumped.
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else { return "Missing path" }
            switch AgentWorkspace.shared.resolve(rawPath, write: false) {
            case .denied(let reason):
                return reason
            case .granted(let fileURL):
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return "File not found: \(fileURL.path)"
                }
                guard let data = FileManager.default.contents(atPath: fileURL.path) else {
                    return "Could not read \(fileURL.path)"
                }
                if data.contains(0) {
                    return "Binary file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))) — not shown as text"
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                return text.count > 60_000 ? String(text.prefix(60_000)) + "…[truncated]" : text
            }

        case "listDirectory":
            let raw = args["path"] as? String ?? ""
            let target: URL
            switch AgentWorkspace.shared.resolve(raw, write: false) {
            case .denied(let reason):
                return reason
            case .granted(let url):
                target = raw.isEmpty ? AgentWorkspace.shared.directory : url
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
                return "Could not list \(target.path)"
            }
            var lines: [String] = ["\(target.path)"]
            for entry in entries.prefix(200) {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let kind = isDir ? "dir " : "file"
                let sizeText = isDir ? "" : "  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
                lines.append("- [\(kind)] \(entry.lastPathComponent)\(sizeText)")
            }
            return lines.joined(separator: "\n")

        // --- Recording ---
        case "startRecording":
            // Records THIS window (the whole browser window, chat included —
            // perfect for "watch me work" demos). First call triggers the
            // macOS Screen Recording permission dialog.
            guard let window = webView.window else { return "No window attached" }
            do {
                let url = try await WindowRecorder.shared.start(window: window)
                return "Recording started → \(url.lastPathComponent). Perform the steps now; call stopRecording when finished."
            } catch {
                return "Could not start recording: \(error.localizedDescription)"
            }

        case "stopRecording":
            guard WindowRecorder.shared.isRecording else { return "Not recording" }
            guard let url = await WindowRecorder.shared.stop() else {
                return "Recording stopped but the file could not be finalized"
            }
            let duration: String
            if let started = WindowRecorder.shared.startedAt {
                duration = String(format: "%.0f", Date().timeIntervalSince(started)) + "s"
            } else {
                duration = "?"
            }
            return "Recording saved: \(url.path) (\(duration))"

        // --- Agent host: system CLI + skills ---
        case "runCommand":
            // Allowlisted binary, argv-only (no shell). ToolRisk marks this
            // DANGEROUS: every call prompts with the exact command line
            // unless the user enabled FULL ACCESS.
            guard let tool = args["tool"] as? String, !tool.isEmpty else {
                return "Missing tool (allowlisted: \(SystemCommandStore.shared.allowedBinaries.sorted().joined(separator: ", ")))"
            }
            let commandArgs = args["args"] as? [String] ?? []
            let timeout = args["timeoutSec"] as? Double ?? 120
            let result = await SystemCommandStore.shared.run(
                tool: tool, args: commandArgs, timeout: timeout,
                workDirectory: AgentWorkspace.shared.directory
            )
            return "runCommand \(result.summary)\n\(result.stdout)\(result.stderr == "" ? "" : "\n\(result.stderr)")"

        case "useSkill":
            // Progressive disclosure: the name+description list rides in the
            // prompt; this loads the FULL instructions into the conversation.
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Missing skill name. Available: \(SkillStore.shared.skills.map(\.name).joined(separator: ", "))"
            }
            guard let body = SkillStore.shared.body(for: name) else {
                return "Skill not found: \(name). Available: \(SkillStore.shared.skills.map(\.name).joined(separator: ", "))"
            }
            return "Skill '\(name)' loaded. Follow these instructions:\n\(body)"

        case "listSkills":
            let skills = SkillStore.shared.skills
            if skills.isEmpty { return "No skills installed (drop .md files into Application Support/Desire/skills)" }
            return "Installed skills:\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        case "copyToClipboard":
            guard let text = args["text"] as? String else { return "Missing text" }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "Copied to clipboard: \(preview)"

        case "readClipboard":
            // Side-effect tier on purpose: the clipboard may hold sensitive
            // content, so ToolRisk.classify leaves this at .sideEffect and
            // the user is asked (with an Always-Allow option) first.
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if text.isEmpty { return "Clipboard is empty (or holds non-text content)" }
            return text.count > 2000
                ? String(text.prefix(2000)) + "…[truncated]"
                : text

        case "fill":
            guard let val = args["value"] as? String else { return "Missing value" }
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return "Provide selector or ref" }
            return await callAsync(webView, function: "__desireFill",
                                   args: ["selector": sel ?? "", "value": val, "ref": ref ?? ""])

        case "select":
            guard let val = args["value"] as? String else { return "Missing value" }
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return "Provide selector or ref" }
            return await callAsync(webView, function: "__desireSelect",
                                   args: ["selector": sel ?? "", "value": val, "ref": ref ?? ""])

        case "scroll":
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            return await callAsync(webView, function: "__desireScroll", args: ["x": x, "y": y])

        case "hover":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return "Provide one of: ref, text, or selector"
            }
            // Trusted mouse-moved stream, same rationale as `click`.
            if let point = await clickablePoint(selector: sel, ref: ref, text: text, in: webView) {
                await SyntheticInput.hover(at: point, in: webView)
                return "Hovered (trusted mouse events)"
            }
            return await callAsync(webView, function: "__desireHover",
                                   args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])

        case "focus":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return "Provide selector or ref" }
            return await callAsync(webView, function: "__desireFocus",
                                   args: ["selector": sel ?? "", "ref": ref ?? ""])

        case "pressKey":
            // Trusted keyboard event through the AppKit pipeline (the page
            // becomes first responder for the duration). Covers Enter-on-
            // search, Escape-on-modal, arrow/tab navigation, ⌘A-style combos.
            guard let key = args["key"] as? String, !key.isEmpty else {
                return "Missing key. Supported: \(SyntheticInput.supportedKeys)"
            }
            var flags: NSEvent.ModifierFlags = []
            if let mods = args["modifiers"] as? [String] {
                for m in mods {
                    switch m.lowercased() {
                    case "cmd", "command", "⌘": flags.insert(.command)
                    case "shift", "⇧": flags.insert(.shift)
                    case "ctrl", "control", "⌃": flags.insert(.control)
                    case "alt", "option", "opt", "⌥": flags.insert(.option)
                    default: break
                    }
                }
            }
            return await SyntheticInput.key(key, modifiers: flags, in: webView)

        case "type":
            // Trusted per-character typing into the FOCUSED element. Unlike
            // fill (prototype setter), real key events fire — autocomplete,
            // search-as-you-type, and keydown-driven widgets respond.
            guard let text = args["text"] as? String, !text.isEmpty else { return "Missing text" }
            // Optional focus target first; typing lands in the page either way.
            if let sel = args["selector"] as? String, !sel.isEmpty {
                _ = await callAsync(webView, function: "__desireFocus",
                                    args: ["selector": sel, "ref": args["ref"] as? String ?? ""])
            } else if let ref = args["ref"] as? String, !ref.isEmpty {
                _ = await callAsync(webView, function: "__desireFocus",
                                    args: ["selector": "", "ref": ref])
            }
            return await SyntheticInput.type(text, in: webView)

        case "waitForText":
            // Wait until visible text appears (e.g. search results render).
            guard let text = args["text"] as? String, !text.isEmpty else { return "Missing text" }
            let timeout = args["timeout"] as? Int ?? 8000
            return await callAsync(webView, function: "__desireWaitForText",
                                   args: ["text": text, "timeout": timeout])

        case "getFormFields":
            // Structured form inventory (ref/type/name/label/value/options)
            // with data-desire-ref ids assigned — fill {ref} targets them.
            return await callAsync(webView, function: "__desireGetFormFields", args: [:])

        case "postComment":
            // One-shot "评论/回复/回消息": locates the page's comment or
            // chat input automatically (textarea or contenteditable editor),
            // types through the framework-compatible editing path, then
            // submits — trusted click on the 发送/发表/Send button when one
            // exists (rect comes back from the page), otherwise Enter.
            guard let text = args["text"] as? String, !text.isEmpty else { return "Missing text" }
            let submit = args["submit"] as? Bool ?? true
            let raw = await callAsync(webView, function: "__desirePostComment",
                                      args: ["text": text, "submit": submit])
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return raw.isEmpty ? "No comment or chat input found on this page" : raw
            }
            let status = obj["status"] as? String ?? "Typed"
            guard submit,
                  let rect = obj["submitRect"] as? [String: Double],
                  let x = rect["x"], let y = rect["y"],
                  let w = rect["w"], let h = rect["h"], w > 0, h > 0 else {
                return status
            }
            let point = windowPoint(fromViewportX: x + w / 2, y: y + h / 2, in: webView)
            await SyntheticInput.click(at: point, in: webView)
            return status + " — submitted"

        case "extract":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await callAsync(webView, function: "__desireExtract", args: ["selector": sel])

        case "findElements":
            guard let sel = args["selector"] as? String else { return "Missing selector" }
            return await callAsync(webView, function: "__desireFindElements", args: ["selector": sel])

        // --- Utilities ---
        case "wait":
            // Capped so a misbehaving plan can't stall the loop for minutes.
            let ms = min(args["ms"] as? Int ?? 1000, 60_000)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return "[Cancelled]" }
            return "Waited \(ms)ms"

        case "waitForElement":
            let sel = args["selector"] as? String ?? ""
            let timeout = min(args["timeout"] as? Int ?? 5000, 60_000)
            return await callAsync(webView, function: "__desireWaitForElement", args: ["selector": sel, "timeout": timeout])

        case "executeJS":
            guard let code = args["code"] as? String else { return "Missing code" }
            let result = await eval(webView, code)
            return result.isEmpty ? "Executed (no return value)" : result

        default:
            // MCP-bridged tools ride the same dispatch path with the same
            // approval gating as built-ins.
            if call.function.name.hasPrefix("mcp_") {
                return await MCPStore.shared.callTool(defName: call.function.name,
                                                      argumentsJSON: call.function.arguments)
            }
            return "Unknown tool: \(call.function.name)"
        }
    }

    /// Resolves the target (selector / snapshot ref / visible text — the
    /// same resolution the JS fallback uses) to its center point in
    /// window-base coordinates (what `NSEvent.mouseEvent(location:)`
    /// expects) after scrolling the element into view. Returns nil when the
    /// webview has no window, the element is missing, or it has no
    /// on-screen geometry — callers then fall back to the in-page JS path.
    private func clickablePoint(selector: String?, ref: String?, text: String?, in webView: WKWebView) async -> CGPoint? {
        guard webView.window != nil else { return nil }
        let raw = await callAsync(webView, function: "__desireElementRect",
                                  args: ["selector": selector ?? "", "ref": ref ?? "", "text": text ?? ""])
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
