import AppKit
import os
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
            let ignoreSelsJSON = (try? String(data: JSONEncoder().encode(
                surface.tabManager?.selectedTab?.browser.effectiveProtocol?.ignore ?? []), encoding: .utf8)) ?? "[]"
            let snapshot = await callAsync(webView, function: "__desireSnapshot",
                                   args: ["maxChars": maxChars, "maxElements": maxElements,
                                          "ignoreSels": ignoreSelsJSON])
            // DPP 声明页：低效工具的返回里也提示结构化通道（实测模型在翻译/
            // 总结类任务上会跳过 pageProtocol——让提示跟到最常用的工具上）。
            // 先等解析落地（didFinish 异步任务，普通页面 <300ms；与 navigate
            // 同款竞态——首个工具调用会比解析早到）
            let ownTab = surface.tabManager?.tabs.first(where: { $0.browser.webView === webView })
            var waited = 0
            while waited < 8, ownTab?.browser.pageProtocolChecked == false {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 1
            }
            Log.agent.info("DPP snapshot hint: ownTab=\(ownTab != nil) checked=\(ownTab?.browser.pageProtocolChecked ?? false) proto=\(ownTab?.browser.effectiveProtocol != nil) selProto=\(surface.tabManager?.selectedTab?.browser.effectiveProtocol != nil) waits=\(waited)")
            // hint 前置：工具消息统一 prefix(8000)，快照 JSON 本身 ~7KB——
            // 追加在尾部会被截断剪掉（实测）。DPP 配置关提示时不注入。
            if DPPConfigStore.shared.promptHints,
               ownTab?.browser.effectiveProtocol != nil
                || surface.tabManager?.selectedTab?.browser.effectiveProtocol != nil {
                // 适配包来源透出：协议来自第三方适配包时 Agent 知道（声明
                // 精度与站点原生声明不同档，行动前可多一分核对意识）。
                var via = ""
                let warningTexts = surface.tabManager?.selectedTab?.browser.effectiveProtocol?.warnings ?? []
                let adapterNames = warningTexts.compactMap { w -> String? in
                    w.hasPrefix("adapter: ") ? String(w.dropFirst("adapter: ".count)) : nil
                }
                if !adapterNames.isEmpty {
                    via = " (via community adapter: \(adapterNames.joined(separator: ", ")))"
                }
                return "[DPP] This page declares a Desire Page Protocol\(via) — use pageProtocol to see it, pageExtract for structured data, pageAction for declared actions.\n" + snapshot
            }
            return snapshot
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
            let targetIgnoresJSON = (try? String(data: JSONEncoder().encode(
                target.browser.effectiveProtocol?.ignore ?? []), encoding: .utf8)) ?? "[]"
            let snapshot = await callAsync(target.browser.webView, function: "__desireSnapshot",
                                           args: ["maxChars": 6000, "maxElements": 25,
                                                  "ignoreSels": targetIgnoresJSON])
            let dppNote = DPPConfigStore.shared.promptHints
                && target.browser.effectiveProtocol != nil
                ? "[DPP] This page declares a Desire Page Protocol — pageExtract for structured data.\n"
                : ""
            return dppNote + "[\(target.displayTitle) — \(target.browser.webView.url?.host ?? "")]\n\(snapshot)"

        case "getPageText":
            // DPP content.sections（§4.3）：给了 section 就只读该命名分区——
            // 长文/多面板页面按语义分区读，省 token 也更准。未知分区不猜，
            // 把可用分区名列出来引导模型改参。
            if let sectionName = args["section"] as? String, !sectionName.isEmpty {
                let proto = surface.tabManager?.selectedTab?.browser.effectiveProtocol
                if let selector = proto?.sections[sectionName], !selector.isEmpty {
                    let selLit = JSString.literal(selector)
                    let text = await eval(webView, """
                    (function(){var m = __desireQueryAll(\(selLit))[0] || document.querySelector(\(selLit)); return m ? m.innerText : '';})()
                    """)
                    return text.isEmpty ? "Section '\(sectionName)' matched nothing on this page" : text
                }
                let available = (proto?.sections.keys.sorted().map { "'\($0)'" } ?? []).joined(separator: ", ")
                return Self.fail("Unknown section '\(sectionName)'\(available.isEmpty ? " — this page declares no sections" : " — available: \(available)")")
            }
            // DPP contentMain：页面声明了正文选择器就只取正文（排除导航/
            // 页脚噪音）；选择器落空时回退 body（声明不可信时不比原来差）。
            if let main = surface.tabManager?.selectedTab?.browser.effectiveProtocol?.contentMain,
               !main.isEmpty {
                let mainLit = JSString.literal(main)
                // ignore 声明：克隆正文、剔除噪音子树后再取文本（innerText 在
                // 分离节点上回退 textContent，故手动补块级换行保持分段）。
                // 无 ignore 声明时保留原 innerText 快路径。
                let ignores = surface.tabManager?.selectedTab?.browser.effectiveProtocol?.ignore ?? []
                if ignores.isEmpty {
                    let text = await eval(webView, """
                    (function(){var m = document.querySelector(\(mainLit)); return (m || document.body).innerText;})()
                    """)
                    return text
                }
                let ignoresJSON = (try? String(data: JSONEncoder().encode(ignores), encoding: .utf8)) ?? "[]"
                let mainClone = """
                (function(){
                  var m = document.querySelector(\(mainLit)) || document.body;
                  var c = m.cloneNode(true);
                  (JSON.parse(\(JSString.literal(ignoresJSON))) || []).forEach(function(sel){
                    try { c.querySelectorAll(sel).forEach(function(e){ e.remove(); }); } catch (e) {}
                  });
                  c.querySelectorAll('br').forEach(function(e){ e.replaceWith('\n'); });
                  ['p','div','li','tr','section','article','h1','h2','h3','h4','h5','h6','pre','blockquote'].forEach(function(t){
                    c.querySelectorAll(t).forEach(function(e){
                      e.insertBefore(document.createTextNode('\n'), e.firstChild);
                      e.appendChild(document.createTextNode('\n'));
                    });
                  });
                  return (c.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
                })()
                """
                return await eval(webView, mainClone)
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
            let maxItems = min(500, max(1, args["maxItems"] as? Int ?? 100))
            // 原生读 DevToolsStore（本 tab 的请求记录；第三轮指导 4——
            // 摆脱页面世界 network-tools，page-world 网络依赖只剩 WaitForNetworkIdle）
            let tab = surface.tabManager?.tabs.first(where: { $0.browser.webView === webView })
                ?? surface.tabManager?.selectedTab
            let all = surface.devToolsStore.networkRequests
                .filter { $0.tabID == nil || $0.tabID == tab?.id }
            let matched = Array(all
                .filter { filter.isEmpty || $0.url.localizedCaseInsensitiveContains(filter) }
                .suffix(maxItems))
            guard !matched.isEmpty else {
                return filter.isEmpty
                    ? "No requests captured"
                    : "No requests captured matching filter"
            }
            let rows = matched.map { r -> String in
                var line = "\(r.method) \(r.url)"
                if let code = r.statusCode { line += " → \(code)" }
                if let ms = r.duration { line += String(format: " (%.0fms)", ms * 1000) }
                return line
            }
            return "Captured \(all.count) request(s)\(filter.isEmpty ? "" : ", \(matched.count) matching '\(filter)'") (latest \(rows.count)):\n" + rows.joined(separator: "\n")

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
            // 实际承载导航的 webview（window 参数跨窗时 ≠ 传入的 webView）——
            // 后续一切轮询/读取都必须用它，否则 CF 检测/标题/DPP 全部看错页面。
            let nav = targetWebView
            // 第十一批：Cloudflare 挑战页自愈等待——load 返回即读页会看到
            // "Just a moment" 挑战页，agent 判定失败 → 重试 → 触发更多挑战。
            // 主框架加载完成后轮询标题（挑战通过即消失），最长 15s。仍在挑战
            // 则明确告知模型需要人工处理，勿重试。
            let cfMarkers = ["just a moment", "checking your browser",
                             "verify you are human", "attention required", "请稍候"]
            let deadline = Date().addingTimeInterval(15)
            var challengeReported = false
            while Date() < deadline {
                if !nav.isLoading {
                    let title = (nav.title ?? "").lowercased()
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
                let stillChallenge = cfMarkers.contains(where: { (nav.title ?? "").lowercased().contains($0) })
                if stillChallenge {
                    return "Navigated to \(url) — Cloudflare human-verification page is STILL showing. Ask the user to complete the check in the browser window. Do NOT retry navigation."
                }
                return "Navigated to \(url) — a Cloudflare check appeared and cleared automatically."
            }
            // 首载健康自愈（2026-10-15 实机：掘金/红迪风控局域页会 "complete"
            // 但近乎空文档——标题正常、无 CF 标记，直接放行会让模型对着空页
            // 瞎猜）。判定 → 自动重载一次 → 再判一次，结果如实写进回包。
            var loadHealthNote = ""
            if let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                if let first = await Self.pageHealth(nav), PageLoadHealth.suspectEmptyDocument(first) {
                    nav.reload()
                    let reloadDeadline = Date().addingTimeInterval(10)
                    while Date() < reloadDeadline, nav.isLoading {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let second = await Self.pageHealth(nav), PageLoadHealth.suspectEmptyDocument(second) {
                        loadHealthNote = "\n（首载与重载后都近乎空文档——疑似站点风控局域页；可稍后重试或请用户在窗口里过一下验证）"
                    } else {
                        loadHealthNote = "\n（首载近乎空文档，已自动重载一次，页面已正常）"
                    }
                }
            }
            // 导航反馈增强：返回页面标题 + 首段文本 + DPP 视图提示。
            // 模型免调 getPageText 就知道页面有什么。
            let pageTitle = nav.title ?? ""
            let snippet: String = await {
                let raw = try? await nav.evaluateJavaScript(
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
                dpp = targetManager.tabs.first(where: { $0.browser.webView === nav })?.browser.effectiveProtocol
                    ?? (nav === targetTab?.browser.webView ? targetTab?.browser.effectiveProtocol : nil)
                if dpp != nil { break }
                if targetTab?.browser.pageProtocolChecked == true { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            var readyNote = ""
            if let readySel = dpp?.signals["ready"], !readySel.isEmpty {
                let readyJS = "return __desireQueryAll(\(JSString.literal(readySel))).length > 0"
                var readySeen = false
                for _ in 0..<30 {
                    readySeen = ((try? await nav.callAsyncJavaScript(
                        readyJS, arguments: [:], in: nil, contentWorld: WebView.agentToolWorld) as? Bool) == true)
                    if readySeen { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                readyNote = readySeen
                    ? "\n[DPP] Ready signal observed."
                    : "\n[DPP] Ready signal '\(readySel)' NOT observed within 6s — the page may still be loading or the signal is misdeclared."
            }
            // stable 信号（§4.2）：ready = 首屏渲染，stable = 数据不再变化
            // （懒加载/分页拉取结束）。有声明时 ready 后继续等，避免读到骨架屏。
            var stableNote = ""
            if false, let stableSel = dpp?.signals["stable"], !stableSel.isEmpty { // BISECT: disabled
                let stableJS = "return __desireQueryAll(\(JSString.literal(stableSel))).length > 0"
                var stableSeen = false
                for _ in 0..<30 {
                    stableSeen = ((try? await nav.callAsyncJavaScript(
                        stableJS, arguments: [:], in: nil, contentWorld: WebView.agentToolWorld) as? Bool) == true)
                    if stableSeen { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                stableNote = stableSeen
                    ? "\n[DPP] Stable signal observed — page data is complete."
                    : "\n[DPP] Stable signal '\(stableSel)' NOT observed within 6s — data may still be loading."
            }
            var dppHint = ""
            if DPPConfigStore.shared.promptHints, let dpp, !dpp.isEmpty {
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
                if !dpp.sections.isEmpty {
                    dppHint += "\n[DPP] Named sections (getPageText with section): " + dpp.sections.keys.sorted().joined(separator: ", ")
                }
            }
            var result = "Navigated to \(url) — \(pageTitle)"
            if !loadHealthNote.isEmpty { result += loadHealthNote }
            if !snippet.isEmpty { result += "\n\(snippet)" }
            if !readyNote.isEmpty { result += readyNote }
            if !stableNote.isEmpty { result += stableNote }
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
            let items = tabs.enumerated().map { i, tab -> String in
                var marks: [String] = []
                if tab.isPinned { marks.append("pinned") }
                if tab.audioMuted { marks.append("muted") }
                if tab.isIncognito { marks.append("incognito") }
                let zoom = tab.browser.webView.pageZoom
                if abs(zoom - 1.0) > 0.01 { marks.append("zoom \(Int((zoom * 100).rounded()))%") }
                let prefix = marks.isEmpty ? "" : "[" + marks.joined(separator: ",") + "] "
                return "[\(i)] \(prefix)\(tab.displayTitle) — \(tab.urlString)"
            }
            return items.joined(separator: "\n")

        // --- Tab Crew (0.3.1) ---
        case "crewDispatch":
            let objective = args["objective"] as? String ?? "research task"
            let rawTasks = args["tasks"] as? [[String: Any]] ?? []
            let tasks = rawTasks.map { t -> (url: String?, instruction: String) in
                (t["url"] as? String, t["instruction"] as? String ?? "")
            }
            let isolated = args["isolated"] as? Bool ?? false
            return AgentCrewStore.shared.dispatch(objective: objective, tasks: tasks,
                                                  surface: surface, isolated: isolated)

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

        case "listArchivedSessions":
            // 已关窗口的会话归档（保留最近 5 个）——"我关掉的那扇窗还能找回吗"。
            let archives = SessionArchive.list(in: TabSessionCoordinator.archiveDirectory)
            guard !archives.isEmpty else { return "No archived sessions" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return archives.map { entry in
                var line = "\(entry.fileName) — \(entry.tabCount) tab(s) — archived \(formatter.string(from: entry.savedAt))"
                if !entry.topURLs.isEmpty {
                    line += "\n  " + entry.topURLs.prefix(2).joined(separator: ", ")
                }
                return line
            }.joined(separator: "\n")

        case "restoreArchivedSession":
            // 把归档会话恢复到**当前窗口**（替换其标签，与工作区恢复同语义）。
            guard let archiveFile = args["file"] as? String, !archiveFile.isEmpty else {
                return Self.fail("Missing file (see listArchivedSessions)")
            }
            guard let archiveManager = surface.tabManager else { return Self.fail("No window") }
            guard TabSessionCoordinator.isSafeArchiveName(archiveFile) else {
                return Self.fail("Bad archive file name (use the exact file from listArchivedSessions)")
            }
            guard let restoredTabs = TabSessionCoordinator.shared.restoreArchivedSession(
                named: archiveFile, into: archiveManager,
                settings: surface.settings, contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker) else {
                return Self.fail("Couldn't read archive: \(archiveFile) (deleted or corrupt?)")
            }
            return "Restored archived session \(archiveFile) — \(restoredTabs) tab(s) now open in this window (previous tabs were replaced)"

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

        case "pinTab":
            // 固定/取消固定（固定标签显示在最前、'关其他标签'豁免、免自动挂起）。
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs open") }
            let pinIndex = (args["index"] as? Int) ?? manager.selectedIndex
            guard manager.tabs.indices.contains(pinIndex) else { return Self.fail("Invalid tab index") }
            let pinTarget = manager.tabs[pinIndex]
            let wantPinned = (args["pinned"] as? Bool) ?? !pinTarget.isPinned
            pinTarget.isPinned = wantPinned
            return "\(wantPinned ? "Pinned" : "Unpinned") tab \(pinIndex) — \(pinTarget.displayTitle)"

        case "muteTab":
            // 静音是劫持式的（TabAudioControl）：站点自己的取消静音脚本会被挡。
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs open") }
            let muteIndex = (args["index"] as? Int) ?? manager.selectedIndex
            guard manager.tabs.indices.contains(muteIndex) else { return Self.fail("Invalid tab index") }
            let muteTarget = manager.tabs[muteIndex]
            let wantMuted = (args["muted"] as? Bool) ?? !muteTarget.audioMuted
            muteTarget.audioMuted = wantMuted
            let hijackNote = wantMuted ? " (site unmute attempts are blocked)" : ""
            return "\(wantMuted ? "Muted" : "Unmuted") tab \(muteIndex) — \(muteTarget.displayTitle)\(hijackNote)"

        case "moveTab":
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs open") }
            guard let moveFrom = args["from"] as? Int, let moveTo = args["to"] as? Int,
                  manager.tabs.indices.contains(moveFrom), moveTo >= 0, moveTo < manager.tabs.count,
                  moveFrom != moveTo else {
                return Self.fail("Invalid from/to (0-based indices within the tab list, from ≠ to)")
            }
            // 工具语义 = "移动后落在下标 to"；TabManager.moveTab 是 onMove 的
            // 插入位语义（from < to 时要 +1 平移，否则会差一位）。
            manager.moveTab(from: moveFrom, to: moveFrom < moveTo ? moveTo + 1 : moveTo)
            let landed = manager.tabs.indices.contains(moveTo) ? manager.tabs[moveTo].displayTitle : "?"
            return "Moved tab \(moveFrom) → \(moveTo) — \(landed)"

        case "splitView":
            // 分屏右栏（工具栏分屏按钮同路径；桥 /split 同 API）。
            guard let manager = surface.tabManager, manager.tabs.count >= 2 else {
                return Self.fail("Need at least 2 tabs to split")
            }
            let selected = manager.selectedIndex
            let partnerIndex: Int
            if let requested = args["index"] as? Int {
                partnerIndex = requested
            } else if selected + 1 < manager.tabs.count {
                partnerIndex = selected + 1
            } else {
                partnerIndex = 0
            }
            guard manager.tabs.indices.contains(partnerIndex), partnerIndex != selected else {
                return Self.fail("Pick a different tab for the right pane (0-based index)")
            }
            manager.setSplitPartner(at: partnerIndex)
            let leftTitle = manager.tabs[selected].displayTitle
            let rightTitle = manager.tabs[partnerIndex].displayTitle
            return "Split view: \(leftTitle) | \(rightTitle) (right pane = tab \(partnerIndex))"

        case "unsplitView":
            guard let manager = surface.tabManager else { return Self.fail("No window") }
            guard manager.splitPartnerID != nil else { return "Not in split view" }
            manager.setSplitPartner(at: nil)
            return "Left split view"

        case "setZoom":
            guard let percent = args["percent"] as? Int else { return Self.fail("Missing percent") }
            let clamped = min(500, max(25, percent))
            guard let zoomTab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
            zoomTab.applyPageZoom(Double(clamped) / 100.0, rememberIn: surface.siteSettingsStore)
            return "Zoom set to \(clamped)%"

        case "newWindow":
            // 新窗口（菜单 File ▸ New Window 同路径）。**先激活应用再发命令**：
            // CommandBus 的消费守卫是 hostingWindow === NSApp.keyWindow，
            // 应用在后台时 keyWindow 为空 → 命令会被所有窗口丢掉（实测：
            // 后台跑 E2E 时这一步永远失败）。带 url 时等新窗口的 TabManager
            // 注册（注册点在 TabManager.init）后在其中开标签。
            NSApp.activate(ignoringOtherApps: true)
            let beforeManagers = Set(TabSessionCoordinator.shared.liveManagers().map(ObjectIdentifier.init))
            // 走 NotificationCenter + **按会话点名**，不走 CommandBus：后者有
            // key-window 守卫，应用在后台时（keyWindow 为空）命令会被所有窗口
            // 丢掉——实测后台调 newWindow 3/3 失败（即使先 activate 也来不及）。
            // 监听侧只让"这个会话所在的那一扇窗"开新窗，广播天然收敛到唯一。
            var windowRequest: [String: Any] = [:]
            if let owner = ownerSession,
               let entryID = AgentScheduler.shared.liveSessions()
                   .first(where: { $0.store === owner })?.id.uuidString {
                windowRequest["session"] = entryID
            }
            NotificationCenter.default.post(name: .desireOpenNewWindow, object: nil,
                                            userInfo: windowRequest.isEmpty ? nil : windowRequest)
            var freshManager: TabManager?
            for _ in 0..<26 {
                try? await Task.sleep(for: .milliseconds(150))
                if let fresh = TabSessionCoordinator.shared.liveManagers()
                    .first(where: { !beforeManagers.contains(ObjectIdentifier($0)) }) {
                    freshManager = fresh
                    break
                }
            }
            guard let freshManager else {
                return Self.fail("Couldn't open a new window (the command goes to the key window — focus a Desire browser window and retry)")
            }
            if let windowURL = args["url"] as? String, !windowURL.isEmpty {
                freshManager.addTab(url: windowURL,
                                    javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                                    contentBlocker: surface.contentBlocker,
                                    videoAdBlocker: surface.videoAdBlocker)
            }
            // 到前台并取 key：应用在后台时新窗口只是"创建"而不成 key——那样
            // deliveryTarget/键命令都还留在旧窗（E2E 实测踩到）。**用 AppKit
            // 窗口差集找新窗**：不带 URL 时新窗展示的是原生新标签页（没有
            // webview），`selectedTab?.browser.webView.window` 永远拿不到宿主，
            // 实测那条路径开窗后焦点一直不落（工具只能回"created but couldn't
            // be focused"）。
            NSApp.activate(ignoringOtherApps: true)
            let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            var keyed = false
            for _ in 0..<13 {
                try? await Task.sleep(for: .milliseconds(150))
                if let freshWindow = NSApp.windows.first(where: { !windowsBefore.contains(ObjectIdentifier($0)) }) {
                    freshWindow.makeKeyAndOrderFront(nil)
                    keyed = true
                    break
                }
            }
            let opened = (args["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                .map { "Opened a new window with \($0)" } ?? "Opened a new window"
            return opened + (keyed ? "" : " (window created but couldn't be focused)")

        case "closeWindow":
            // 关掉**本会话所在窗口**。走会话点名的通知（与 newWindow 同路径）：
            // 后台窗口的选中标签可能已挂起（webView 不在任何窗口上），
            // `webView.window` 拿不到宿主 → 实测关不掉后台窗口；ContentView
            // 持有 hostingWindow 引用，不受挂起影响。
            let hostTabCount = surface.tabManager?.tabs.count ?? 0
            var closeRequest: [String: Any] = [:]
            if let owner = ownerSession,
               let entryID = AgentScheduler.shared.liveSessions()
                   .first(where: { $0.store === owner })?.id.uuidString {
                closeRequest["session"] = entryID
            }
            NotificationCenter.default.post(name: .desireCloseWindow, object: nil,
                                            userInfo: closeRequest.isEmpty ? nil : closeRequest)
            return "Closed the window (\(hostTabCount) tab(s))"

        case "openIncognitoTab":
            let privateURL = args["url"] as? String
            surface.tabManager?.addTab(
                url: privateURL,
                incognito: true,
                javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                contentBlocker: surface.contentBlocker,
                videoAdBlocker: surface.videoAdBlocker,
                autoPlayPolicy: surface.settings.autoPlayPolicy,
                newTabPosition: surface.settings.newTabPosition
            )
            let urlNote = privateURL.map { " with \($0)" } ?? ""
            return "Opened a private tab\(urlNote) — not recorded in history"

        case "saveWorkspace":
            // 工作区 = 当前窗口全部标签的命名快照（与工作区面板「保存当前」同路径）。
            guard let manager = surface.tabManager, !manager.tabs.isEmpty else { return Self.fail("No tabs to save") }
            guard let wsName = args["name"] as? String,
                  !wsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.fail("Missing name")
            }
            let saved = WorkspaceStore.shared.save(name: wsName, tabManager: manager)
            return "Saved workspace \"\(saved.name)\" (\(saved.session.tabs.count) tab(s))"

        case "listWorkspaces":
            let allWorkspaces = WorkspaceStore.shared.workspaces
            guard !allWorkspaces.isEmpty else { return "No workspaces saved" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return allWorkspaces.map { ws in
                "\(ws.name) — \(ws.session.tabs.count) tab(s) — saved \(formatter.string(from: ws.savedAt))"
            }.joined(separator: "\n")

        case "restoreWorkspace":
            // 与工作区面板「Restore」同路径：**替换**当前窗口的标签集
            //（选中标签急切恢复、其余挂起），快照里的档案优先。
            guard let manager = surface.tabManager else { return Self.fail("No window") }
            guard let restoreName = args["name"] as? String, !restoreName.isEmpty else { return Self.fail("Missing name") }
            guard let ws = WorkspaceStore.shared.workspace(named: restoreName) else {
                let names = WorkspaceStore.shared.workspaces.map(\.name).joined(separator: ", ")
                return Self.fail("Workspace not found: \(restoreName). Available: \(names.isEmpty ? "(none)" : names)")
            }
            if let pid = ws.session.profileID {
                manager.profileID = pid
                manager.profileDataStore = ProfileStore.shared.dataStore(for: pid)
            }
            manager.apply(session: ws.session,
                          javaScriptEnabled: surface.settings.isJavaScriptEnabled,
                          contentBlocker: surface.contentBlocker,
                          videoAdBlocker: surface.videoAdBlocker)
            return "Restored workspace \"\(ws.name)\" — \(manager.tabs.count) tab(s) now open in this window (previous tabs were replaced)"

        case "deleteWorkspace":
            guard let delName = args["name"] as? String, !delName.isEmpty else { return Self.fail("Missing name") }
            guard let wsToDelete = WorkspaceStore.shared.workspace(named: delName) else {
                return Self.fail("Workspace not found: \(delName)")
            }
            WorkspaceStore.shared.remove(wsToDelete.id)
            return "Deleted workspace \"\(wsToDelete.name)\""

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
            guard let session = ownerSession else {
                return Self.fail("No live agent session to review.")
            }
            return await session.reflectForTool(question: (args["question"] as? String) ?? "")

        case "setTokenBudget":
            // 会话预算（v0.7.18）：改的是**本会话**（工具跑在哪个会话就改哪个）。
            // 档位复位——刚调过预算，从头按新额度算。
            guard let tokens = args["tokens"] as? Int else { return Self.fail("Missing tokens") }
            guard let session = ownerSession else { return Self.fail("No owning agent session") }
            session.setTokenBudget(tokens)
            let budget = (session.budgetSnapshot()["budget"] as? Int) ?? 0
            if budget == 0 { return "Token budget disabled for this conversation." }
            return "Token budget set to \(budget) tokens for this conversation (tier reset)."

        // --- Past conversations ---
        case "searchConversations":
            let query = (args["query"] as? String) ?? ""
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
                return Self.fail("Give me at least 2 characters to search for.")
            }
            let limit = min(20, max(1, (args["limit"] as? Int) ?? 5))
            // 排除当前对话：它已经在模型的上下文里，搜它只是浪费 token。
            let current = ownerSession?.conversationId
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

        case "deleteHistory":
            // 定向清理（清空是 clearHistory 的活；这里必须带至少一个条件，
            // 防"手滑清库"）。时间收 "yyyy-MM-dd" / "yyyy-MM-dd HH:mm" / ISO。
            let history = surface.historyStore
            let beforeCount = history.entries.count
            var applied: [String] = []
            if let domain = args["domain"] as? String,
               !domain.trimmingCharacters(in: .whitespaces).isEmpty {
                history.removeAll(from: domain)
                applied.append("domain \(domain)")
            }
            for (key, isBefore) in [("before", true), ("after", false)] {
                guard let raw = args[key] as? String, !raw.isEmpty else { continue }
                guard let date = SystemIntegrationDates.parse(raw) else {
                    return Self.fail("Unparseable \(key) date: \(raw) (use yyyy-MM-dd or yyyy-MM-dd HH:mm)")
                }
                if isBefore { history.removeAll(before: date) } else { history.removeAll(after: date) }
                applied.append("\(key) \(raw)")
            }
            guard !applied.isEmpty else {
                return Self.fail("Need at least one of: domain / before / after (to wipe everything use clearHistory)")
            }
            let removedCount = beforeCount - history.entries.count
            return "Removed \(removedCount) history entr\(removedCount == 1 ? "y" : "ies") (\(applied.joined(separator: ", ")))"

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

        case "readAloud":
            // 朗读（v0.7.18）：端上 TTS（ReaderSpeechService，零费用、数据不出
            // 机）。给了 text 直接念；没给就取当前页可读正文（隔离世界的
            // __desireReadableArticle，与阅读模式同源启发式）。口播上限
            // 20000 字符，截断如实回报。
            let provided = ((args["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speech = ReaderSpeechService.shared
            if !provided.isEmpty {
                let spoken = String(provided.prefix(20_000))
                speech.speak(spoken)
                let note = spoken.count < provided.count ? " (truncated from \(provided.count))" : ""
                return "Reading aloud on-device: \(spoken.count) chars\(note). Use stopSpeaking to stop."
            }
            let raw = await callAsync(webView, function: "__desireReadableArticle",
                                      args: ["maxChars": 20_000])
            if raw.hasPrefix("Error:") { return raw }
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let obj = parsed as? [String: Any],
                  let body = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else {
                return Self.fail("No readable text found on this page")
            }
            let title = (obj["title"] as? String) ?? ""
            speech.speak(title.isEmpty ? body : "\(title)。\n\(body)")
            let cut = (obj["truncated"] as? Bool) == true ? " (page body truncated at 20000 chars)" : ""
            return "Reading aloud on-device: \(body.count) chars from \(title.isEmpty ? "this page" : "\"\(title)\"")\(cut). Use stopSpeaking to stop."

        case "stopSpeaking":
            ReaderSpeechService.shared.stop()
            return "Speech stopped"

        case "zoomIn":
            // 统一落点（v0.7.18）：菜单/工具栏/工具都走 Tab.applyPageZoom——
            // 双写 + 记每站缩放（否则菜单/工具改的缩放在下次导航被压回去）。
            guard let zoomTab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
            zoomTab.applyPageZoom(zoomTab.browser.pageZoom + 0.1, rememberIn: surface.siteSettingsStore)
            return "Zoomed in to \(Int(zoomTab.browser.pageZoom * 100))%"

        case "zoomOut":
            guard let zoomTab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
            zoomTab.applyPageZoom(zoomTab.browser.pageZoom - 0.1, rememberIn: surface.siteSettingsStore)
            return "Zoomed out to \(Int(zoomTab.browser.pageZoom * 100))%"

        case "resetZoom":
            guard let zoomTab = surface.tabManager?.selectedTab else { return Self.fail("No active tab") }
            zoomTab.applyPageZoom(1.0, rememberIn: surface.siteSettingsStore)
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

        case "listReadingList":
            let readingItems = surface.readingListStore.items
            guard !readingItems.isEmpty else { return "Reading list is empty" }
            return readingItems.map { item -> String in
                var line = "\(item.isRead ? "✓" : "·") \(item.title)\n  \(item.url)"
                if let cached = surface.readingListStore.cacheURL(for: item.id) {
                    line += "\n  [offline copy] \(cached.path)"
                }
                return line
            }.joined(separator: "\n")

        case "cachePageForOffline":
            let cacheURLArg = args["url"] as? String
            let cacheTarget = (cacheURLArg?.isEmpty == false ? cacheURLArg! : webView.url?.absoluteString) ?? ""
            guard !cacheTarget.isEmpty, !isNewTabPage(cacheTarget) else {
                return Self.fail("No URL to cache (pass url, or open the page)")
            }
            let listStore = surface.readingListStore
            guard let listItem = listStore.items.first(where: { $0.url == cacheTarget }) else {
                return Self.fail("Not in the reading list: \(cacheTarget) — add it first (addToReadingList)")
            }
            guard let outcome = await ReadingListCache.capture(url: cacheTarget, itemID: listItem.id) else {
                return Self.fail("Offline capture failed (page never finished loading?)")
            }
            listStore.setCache(listItem.id, fileURL: outcome.fileURL)
            let kb = ByteCountFormatter.string(fromByteCount: Int64(outcome.bytes), countStyle: .file)
            let via = outcome.fromOpenTab ? "（复用已打开标签，含登录态）" : "（后台加载）"
            return "Cached offline: \(listItem.title) (\(kb))\(via) → \(outcome.fileURL.path)"

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

        case "renameTabGroup":
            guard let oldName = args["groupName"] as? String, !oldName.isEmpty,
                  let newName = args["newName"] as? String, !newName.isEmpty else {
                return Self.fail("Missing groupName / newName")
            }
            guard let group = surface.tabGroupStore.groups.first(where: { $0.name == oldName }) else {
                let names = surface.tabGroupStore.groups.map(\.name).joined(separator: ", ")
                return Self.fail("Group not found: \(oldName). Available: \(names.isEmpty ? "(none)" : names)")
            }
            surface.tabGroupStore.rename(group.id, to: newName)
            return "Renamed group \"\(group.name)\" → \"\(newName)\""

        case "collapseTabGroup":
            guard let groupName = args["groupName"] as? String, !groupName.isEmpty else {
                return Self.fail("Missing groupName")
            }
            guard let group = surface.tabGroupStore.groups.first(where: { $0.name == groupName }) else {
                let names = surface.tabGroupStore.groups.map(\.name).joined(separator: ", ")
                return Self.fail("Group not found: \(groupName). Available: \(names.isEmpty ? "(none)" : names)")
            }
            let wantCollapsed = (args["collapsed"] as? Bool) ?? !group.isCollapsed
            surface.tabGroupStore.setCollapsed(group.id, wantCollapsed)
            return "\(wantCollapsed ? "Collapsed" : "Expanded") tab group \"\(group.name)\""

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

    /// 页面健康探针：`contentType:textChars:elementCount`（纯读取；DOM 跨世界共享）。
    fileprivate static func pageHealth(_ webView: WKWebView) async -> PageLoadHealth.Metrics? {
        let js = "(function(){var b=document.body;return document.contentType+':'+(b?(b.innerText||'').trim().length:-1)+':'+document.getElementsByTagName('*').length;})()"
        guard let raw = try? await webView.evaluateJavaScript(js), let value = raw as? String else {
            return nil
        }
        return PageLoadHealth.parseMetrics(value)
    }
}


extension Notification.Name {
    /// 新窗口请求（v26）：由 newWindow 工具发出、按会话点名（userInfo["session"]）
    /// ——只让该会话所在窗口调 openWindow（广播天然收敛到唯一一扇）。
    /// 为什么不用 CommandBus：它有 `hostingWindow === NSApp.keyWindow` 守卫，
    /// 应用在后台时 keyWindow 为空，命令会被所有窗口丢掉（实测 3/3 失败）。
    static let desireOpenNewWindow = Notification.Name("desire.openNewWindow")
}

extension Notification.Name {
    /// 关窗请求（v27）：由 closeWindow 工具按会话点名发出，只让该会话所在
    /// 窗口关自己（与 newWindow 的通知同款收敛；挂起的后台窗口也能关）。
    static let desireCloseWindow = Notification.Name("desire.closeWindow")
}
