import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// ARCH-2 拆分：executeBody 的「页面读取/导航/标签/书签/历史/控制/拦截/下载/
/// 插件/阅读列表/标签组/打印/快拨/搜索引擎/侧栏」域。纯搬运（case 体零改动）；
/// 返回 nil = 本域不认识该工具，主 dispatch 继续。
extension BrowserToolProvider {

    func executePageTools(_ call: AgentToolCall, args: [String: Any], surface: any BrowserToolSurface, in webView: WKWebView) async -> String? {
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
            // window 参数 = 读**另一窗口**的第 index 个标签（多窗口 Agent）。
            let readManager: TabManager?
            if let win = args["window"] as? String, !win.isEmpty {
                readManager = resolveWindowTarget(win)
                if readManager == nil {
                    return Self.fail("Unknown window '\(win.prefix(8))' — call listWindows for valid ids")
                }
            } else {
                readManager = surface.tabManager
            }
            guard let index = args["index"] as? Int,
                  let tabs = readManager?.tabs,
                  tabs.indices.contains(index) else {
                return Self.fail("Invalid tab index (use listTabs\(args["window"] != nil ? " — with window, indexes are THAT window's" : ""))")
            }
            let target = tabs[index]
            guard !target.isSuspended else {
                return Self.fail("Tab \(index) is suspended — switchTab to it first, then readTab")
            }
            let snapshot = await callAsync(target.browser.webView, function: "__desireSnapshot",
                                           args: ["maxChars": 6000, "maxElements": 25])
            return "[\(target.displayTitle) — \(target.browser.webView.url?.host ?? "")]\n\(snapshot)"

        case "getPageText":
            // DPP contentMain：页面声明了正文选择器就只取正文（排除导航/
            // 页脚噪音）；选择器落空时回退 body（声明不可信时不比原来差）。
            if let main = surface.tabManager?.selectedTab?.browser.pageProtocol?.contentMain,
               !main.isEmpty {
                let mainLit = JSString.literal(main)
                let text = await eval(webView, """
                (function(){var m = document.querySelector(\(mainLit)); return (m || document.body).innerText;})()
                """)
                return text
            }
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
                return Self.fail("Provide one of: ref, text, or selector")
            }
            guard let rectData = await callAsync(webView, function: "__desireElementRect",
                    args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""]).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: rectData)) as? [String: Double],
                  let x = obj["x"], let y = obj["y"],
                  let w = obj["w"], let h = obj["h"], w > 1, h > 1 else {
                return Self.fail("Element not found")
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
                    return Self.fail("Capture failed")
                }
                return uri
            } catch {
                return Self.fail("Capture failed: \(error.localizedDescription)")
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
            guard sel != nil || ref != nil || text != nil else { return Self.fail("Provide ref, text, or selector") }
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
            guard let url = args["url"] as? String, !url.isEmpty else { return Self.fail("Missing url") }
            // 无 scheme 输入照地址栏惯例补全（example.com → https://…）；
            // 不像 URL 的输入**明确失败**——此前 `URL(string:"example.com")`
            // 构造成功但 load 静默失败，回包"已导航"（假成功，模型无从重试）。
            let resolvedURL: String
            if url.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil,
               URL(string: url) != nil {
                resolvedURL = url
            } else if let upgraded = URLResolution.upgradedSchemelessURL(url) {
                resolvedURL = upgraded
            } else {
                return Self.fail("Invalid URL '\(url.prefix(80))' — add a scheme (https://…), or use a search tool for keywords")
            }
            guard let u = URL(string: resolvedURL) else { return Self.fail("Invalid URL") }
            // 多窗口：window 参数（会话短 id）指定目标窗口——用**它**的选中
            // 标签执行；缺省 = 自己窗口。找不到该窗口则明确报错。
            var targetManager = surface.tabManager
            if let win = args["window"] as? String, !win.isEmpty {
                guard let tm = resolveWindowTarget(win) else {
                    return Self.fail("Unknown window '\(win.prefix(8))' — call listWindows for valid ids")
                }
                targetManager = tm
            }
            guard let targetManager else { return Self.fail("No window attached") }
            // Mirror BrowsingActions.navigateToURL's state sync. `load` alone
            // is invisible when the tab sits on an overlay: isOnNewTabPage
            // is STORED state (the NewTabPage keeps covering the webview),
            // and an unmounted webview has no navigation delegate to update
            // urlString — so the DOM loads, snapshots read real content, and
            // the user still sees the new-tab page.
            // 跨窗目标：优先目标窗口的选中标签（其 webview 承载导航）。
            let targetTab = targetManager.tabs.first(where: { $0.browser.webView === webView })
                ?? targetManager.selectedTab
            if let tab = targetTab {
                tab.isOnNewTabPage = false
                tab.isSuspended = false
                tab.urlString = u.absoluteString
            }
            let targetWebView = targetTab?.browser.webView ?? webView
            targetWebView.load(URLRequest(url: u))
            // 第十一批：Cloudflare 挑战页自愈等待——load 返回即读页会看到
            // "Just a moment" 挑战页，agent 判定失败 → 重试 → 触发更多挑战。
            // 主框架加载完成后轮询标题（挑战通过即消失），最长 15s。仍在挑战
            // 则明确告知模型需要人工处理，勿重试。
            let cfMarkers = ["just a moment", "checking your browser",
                             "verify you are human", "attention required", "请稍候"]
            let deadline = Date().addingTimeInterval(15)
            var challengeReported = false
            while Date() < deadline {
                if !webView.isLoading {
                    let title = (webView.title ?? "").lowercased()
                    if !challengeReported, !title.isEmpty,
                       cfMarkers.contains(where: { title.contains($0) }) {
                        challengeReported = true
                    }
                    // 挑战页标记出现过且已消失（标题不再匹配）→ 通过
                    if challengeReported && !cfMarkers.contains(where: { title.contains($0) }) {
                        break
                    }
                    // 从未出现挑战标记 → 正常页面，直接返回
                    if !challengeReported, !title.isEmpty {
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if challengeReported {
                let stillChallenge = cfMarkers.contains(where: { (webView.title ?? "").lowercased().contains($0) })
                if stillChallenge {
                    return "Navigated to \(url) — Cloudflare human-verification page is STILL showing. Ask the user to complete the check in the browser window. Do NOT retry navigation."
                }
                return "Navigated to \(url) — a Cloudflare check appeared and cleared automatically."
            }
            // 导航反馈增强：返回页面标题 + 首段文本 + DPP 视图提示。
            // 模型免调 getPageText 就知道页面有什么。
            let pageTitle = webView.title ?? ""
            let snippet: String = await {
                let raw = try? await webView.evaluateJavaScript(
                    "document.body ? document.body.innerText.substring(0, 200) : ''")
                return (raw as? String) ?? ""
            }()
            // DPP：先等协议解析落地（didFinish 里的异步 Task；pageProtocolChecked
            // 区分"没解析完"与"无协议"，普通页面几乎零等待），然后：
            // ① signals.ready —— 声明了就绪信号就等它出现再返回（spec §4.2，
            //    cap 6s；超时如实报告，不让导航假失败）；
            // ② 视图/动作提示与 ready 共用这份协议。
            var dpp: DesireProtocol? = nil
            for _ in 0..<10 {
                dpp = targetManager.tabs.first(where: { $0.browser.webView === webView })?.browser.pageProtocol
                if dpp != nil { break }
                if targetTab?.browser.pageProtocolChecked == true { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            var readyNote = ""
            if let readySel = dpp?.signals["ready"], !readySel.isEmpty {
                let readyJS = "return !!document.querySelector(\(JSString.literal(readySel)))"
                var readySeen = false
                for _ in 0..<30 {
                    readySeen = ((try? await webView.callAsyncJavaScript(
                        readyJS, arguments: [:], in: nil, contentWorld: .page) as? Bool) == true)
                    if readySeen { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                readyNote = readySeen
                    ? "\n[DPP] Ready signal observed."
                    : "\n[DPP] Ready signal '\(readySel)' NOT observed within 6s — the page may still be loading or the signal is misdeclared."
            }
            var dppHint = ""
            if let dpp, !dpp.isEmpty {
                var views: [String] = []
                for (name, view) in dpp.views {
                    views.append("\(name)(fields: \(view.fields.keys.sorted().joined(separator: ",")))")
                }
                if !views.isEmpty {
                    dppHint = "\n[DPP] Structured views available (use pageExtract): " + views.joined(separator: "; ")
                }
                if !dpp.actions.isEmpty {
                    dppHint += "\n[DPP] Actions (use pageAction): " + dpp.actions.map(\.name).joined(separator: ", ")
                }
            }
            var result = "Navigated to \(url) — \(pageTitle)"
            if !snippet.isEmpty { result += "\n\(snippet)" }
            if !readyNote.isEmpty { result += readyNote }
            if !dppHint.isEmpty { result += dppHint }
            return result
        case "goBack":
            guard webView.canGoBack else { return Self.fail("Cannot go back") }
            webView.goBack()
            return "Going back"
        case "goForward":
            guard webView.canGoForward else { return Self.fail("Cannot go forward") }
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
                    return Self.fail("Container not found: \(containerName). Available: \(names.isEmpty ? "(none)" : names)")
                }
                containerID = container.id
                containerNote = " in container \(container.name)"
            }
            surface.tabManager?.addTab(url: url, javaScriptEnabled: jsEnabled, contentBlocker: surface.contentBlocker, videoAdBlocker: surface.videoAdBlocker, containerID: containerID)
            return (url.map { "Opened new tab with \($0)" } ?? "Opened new tab") + containerNote

        case "listContainers":
            let containers = ContainerStore.shared.containers
            guard !containers.isEmpty else { return Self.fail("No containers configured") }
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

        // --- Tab Crew (0.3.1) ---
        case "crewDispatch":
            let objective = args["objective"] as? String ?? "research task"
            let rawTasks = args["tasks"] as? [[String: Any]] ?? []
            let tasks = rawTasks.map { t -> (url: String?, instruction: String) in
                (t["url"] as? String, t["instruction"] as? String ?? "")
            }
            return AgentCrewStore.shared.dispatch(objective: objective, tasks: tasks, surface: surface)

        case "crewStatus":
            return AgentCrewStore.shared.statusReport()

        case "crewCancel":
            if let idx = args["index"] as? Int {
                return AgentCrewStore.shared.cancel(taskIndex: idx)
            }
            AgentCrewStore.shared.cancelAll()
            return "Crew cancelled"

        case "switchTab":
            // window 参数 = 目标窗口（缺省自己窗口）。
            let switchManager: TabManager?
            if let win = args["window"] as? String, !win.isEmpty {
                switchManager = resolveWindowTarget(win)
                if switchManager == nil {
                    return Self.fail("Unknown window '\(win.prefix(8))' — call listWindows for valid ids")
                }
            } else {
                switchManager = surface.tabManager
            }
            guard let index = args["index"] as? Int,
                  index >= 0, index < (switchManager?.tabs.count ?? 0) else { return Self.fail("Invalid tab index") }
            switchManager?.selectTab(at: index)
            let switched = switchManager?.tabs[index]
            let titleSuffix = switched.map { " — " + $0.displayTitle } ?? ""
            let windowSuffix = args["window"] != nil ? " (other window)" : ""
            return "Switched to tab \(index)\(titleSuffix)\(windowSuffix)"

        case "closeOtherTabs":
            // Keep the selected tab, close the rest of THIS window.
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs open") }
            let keep = manager.selectedIndex
            let before = manager.tabs.count
            manager.closeOthers(keeping: keep)
            return "Closed \(before - manager.tabs.count) other tabs"

        case "reopenLastClosedTab":
            guard let manager = surface.tabManager else { return Self.fail("No window") }
            let reopened = manager.reopenLastClosedTab(
                javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker
            )
            return reopened ? "Reopened last closed tab" : "No recently closed tab"

        case "duplicateTab":
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs open") }
            manager.duplicateTab(
                at: manager.selectedIndex,
                javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker
            )
            return "Duplicated current tab"

        // --- Bookmarks ---
        case "addBookmark":
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return Self.fail("No page to bookmark") }
            let title = (args["title"] as? String) ?? (webView.title ?? url)
            surface.bookmarkStore.add(title: title, url: url)
            return "Bookmarked: \(title)"

        case "listBookmarks":
            let all = surface.bookmarkStore.allBookmarks
            guard !all.isEmpty else { return "No bookmarks" }
            return all.map { "\($0.title) — \($0.url ?? "[folder]")" }.joined(separator: "\n")

        case "reflect":
            // 让**模型自己**回头审一遍这一轮：评语返回给它，它据此修正或补验证。
            guard let session = AgentScheduler.shared.deliveryTarget else {
                return Self.fail("No live agent session to review.")
            }
            return await session.reflectForTool(question: (args["question"] as? String) ?? "")

        // --- Past conversations ---
        case "searchConversations":
            let query = (args["query"] as? String) ?? ""
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
                return Self.fail("Give me at least 2 characters to search for.")
            }
            let limit = min(20, max(1, (args["limit"] as? Int) ?? 5))
            // 排除当前对话：它已经在模型的上下文里，搜它只是浪费 token。
            let current = AgentScheduler.shared.deliveryTarget?.conversationId
            let hits = surface.conversationStore.search(query, limit: limit, excluding: current)
            guard !hits.isEmpty else {
                return "No past conversations matched \"\(query)\" (searched \(surface.conversationStore.conversations.count) saved chats)."
            }
            let iso = ISO8601DateFormatter()
            let payload = hits.map { hit -> [String: Any] in
                ["id": hit.id.uuidString, "title": hit.title, "updatedAt": iso.string(from: hit.updatedAt),
                 "messages": hit.messageCount, "matchedIn": hit.matchedIn, "snippet": hit.snippet]
            }
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "search failed"

        case "readConversation":
            guard let rawID = args["id"] as? String, let id = UUID(uuidString: rawID) else {
                return Self.fail("Need a conversation id from searchConversations.")
            }
            let maxChars = min(40_000, max(500, (args["maxChars"] as? Int) ?? 12_000))
            guard let text = surface.conversationStore.transcript(id: id, maxChars: maxChars) else {
                return Self.fail("No saved conversation with id \(rawID).")
            }
            return text

        case "removeBookmark":
            guard let url = args["url"] as? String, let bm = surface.bookmarkStore.find(url: url) else { return Self.fail("Bookmark not found") }
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
            guard let text = args["text"] as? String, !text.isEmpty else { return Self.fail("Missing search text") }
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
            guard let host = webView.url?.host else { return Self.fail("No page loaded") }
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
            guard let url = webView.url?.absoluteString, !url.isEmpty, !isNewTabPage(url) else { return Self.fail("No page to add") }
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
                  let plugin = surface.pluginStore.plugins.first(where: { $0.name == name }) else { return Self.fail("Plugin not found") }
            var updated = plugin
            updated.isEnabled = enabled
            surface.pluginStore.update(updated)
            return enabled ? "Enabled plugin: \(name)" : "Disabled plugin: \(name)"

        // --- Element blocker ---
        case "listBlockedElements":
            let rules = surface.elementBlockStore.rules
            guard !rules.isEmpty else { return "No blocked elements" }
            return rules.map { rule -> String in
                let source = rule.source ?? "agent"
                return "\(rule.cssSelector) — \(rule.urlPattern) [\(source)]"
            }.joined(separator: "\n")

        case "unblockElement":
            guard let selector = args["selector"] as? String,
                  let rule = surface.elementBlockStore.rules.first(where: { $0.cssSelector == selector }) else { return Self.fail("Rule not found") }
            surface.elementBlockStore.remove(id: rule.id)
            // 只有 **ai-auto 来源**的规则被拆才豁免 host（agent/手动规则
            // 是用户显式意图，不触发豁免——豁免语义仅针对"自动拦回去"）。
            if rule.source == "ai-auto",
               let host = webView.url?.host, !host.isEmpty {
                AutoAdClean.shared.exemptHost(host)
                return "Unblocked: \(selector). Auto ad clean is now exempt on \(host) (it won't re-block automatically)."
            }
            return "Unblocked: \(selector)"

        // --- Responsive design ---
        case "toggleResponsiveMode":
            guard let tab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
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
            guard let tab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
            guard let groupName = args["groupName"] as? String else { return Self.fail("Missing group name") }
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
            guard let tab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
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
                                // BUG-5 同类：写盘失败仍报成功 = 静默丢文件。
                                do {
                                    try data.write(to: url)
                                    continuation.resume(returning: "PDF saved to \(url.lastPathComponent)")
                                } catch {
                                    continuation.resume(returning: "Error saving PDF: \(error.localizedDescription)")
                                }
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
            guard let title = args["title"] as? String, let url = args["url"] as? String else { return Self.fail("Missing title or url") }
            surface.quickDialStore.add(title: title, url: url)
            return "Added quick dial: \(title)"

        case "removeQuickDial":
            guard let title = args["title"] as? String,
                  let dial = surface.quickDialStore.dials.first(where: { $0.title == title }) else { return Self.fail("Quick dial not found") }
            surface.quickDialStore.delete(id: dial.id)
            return "Removed quick dial: \(title)"

        // --- Search engine ---
        case "setSearchEngine":
            guard let name = args["engine"] as? String else { return Self.fail("Missing engine name") }
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
            return Self.fail("Invalid engine. Options: \(options)")

        // --- Sidebar ---
        case "toggleSidebar":
            CommandBus.shared.send(.toggleSidebar)
            return "Sidebar toggled"

        default:
            return nil
        }
    }
}
