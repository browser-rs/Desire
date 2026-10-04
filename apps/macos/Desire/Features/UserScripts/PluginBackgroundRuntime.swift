import Combine
import Foundation
import os
import WebKit

/// 插件 background 脚本的常驻运行时（2026-09-29）。
///
/// 每个**启用且带 backgroundCode** 的插件一个 headless WKWebView（永不进窗口，
/// 纯 JS 宿主）：加载 about:blank（baseURL = manifest host_permissions 的
/// origin → 背景脚本里的 fetch 与 API 同源，不受 CORS 限制），注入 webext-api
/// 运行时 + 插件身份 + background 代码。
///
/// 与 Chrome 的差异（刻意取舍，勿"修"）：
/// - `runtime.onInstalled` 在**每次 background 启动**（应用启动/插件启用）都
///   触发，reason 恒为 "install"——配合 contextMenus.create 的原生 upsert
///   幂等，右键菜单跨重启存活；
/// - service worker 换成常驻 webview（扩展后台基本只用 fetch/chrome.*，
///   DOM 缺失无影响）。
///
/// 生命周期：`syncAll()` 在应用启动与插件增/改/删/启用停用时对账
/// （PluginStore.onPluginsChanged 接线）；插件停用或卸载 → 撕掉对应 webview。
@MainActor
final class PluginBackgroundRuntime: NSObject {
    static let shared = PluginBackgroundRuntime()
    private override init() {
        super.init()
        // 启动恢复：磁盘上的 alarms 重新装载并重排 Timer（过期的不重排——
        // 下次对账时视为已过期清掉）。
        if let saved = DiskStore.load([Alarm].self, key: Self.alarmsKey) {
            let now = Date()
            for a in saved where a.scheduledAt > now {
                alarms[a.pluginID.uuidString + "|" + a.name] = a
            }
        }
        // storage.onChanged：set/remove/clear 的统一广播（背景页按监听过滤）。
        WebExtensionStore.changeObserver = { [weak self] ext, changes in
            self?.fireStorageChanged(ext: ext, changes: changes)
        }
    }

    private struct Host {
        let plugin: Plugin
        let webView: WKWebView
        let coordinator: Coordinator
    }

    private var hosts: [UUID: Host] = [:]
    private var wired = false

    // MARK: - 生命周期

    /// 应用启动 / 插件变更后对账：应启的确保在跑，不该跑的停掉。
    func syncAll() {
        guard let store = AppState.live?.pluginStore else { return }
        wireStoreChanges(store)
        let enabled = Set(store.plugins.filter { $0.isEnabled && $0.backgroundCode != nil }.map(\.id))
        Log.userScripts.info("plugin syncAll: \(store.plugins.count) plugins, \(enabled.count) with background")
        // 停：已启动但插件被删/停/不再带后台
        for id in hosts.keys where !enabled.contains(id) {
            stop(id)
        }
        // 启：应启未启的
        for plugin in store.plugins where enabled.contains(plugin.id) && hosts[plugin.id] == nil {
            start(plugin)
        }
    }

    private func start(_ plugin: Plugin) {
        Log.userScripts.info("plugin start attempt: \(plugin.id.uuidString.prefix(8), privacy: .public)")
        guard let code = plugin.backgroundCode, !code.isEmpty else { return }
        let coordinator = Coordinator(pluginID: plugin.id)
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        // 与 popup 同理：background 代码必须与 chrome.* 同处页面世界。
        content.removeScriptMessageHandler(forName: "desireExt", contentWorld: .page)
        content.add(coordinator, contentWorld: .page, name: "desireExt")
        let runtime = UserScriptLoader.load("webext-api")
        if !runtime.isEmpty {
            content.addUserScript(WKUserScript(
                source: runtime + "\nwindow.__desireExtID = '\(plugin.id.uuidString)';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
            content.addUserScript(WKUserScript(
                source: code,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .page))
        }
        // i18n（_locales 表内联，getMessage 同步查表）——在插件代码注入前。
        let i18nPrologue = PluginI18N.prologue(resourcesPath: plugin.resourcesPath)
        if !i18nPrologue.isEmpty {
            content.addUserScript(WKUserScript(
                source: i18nPrologue,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
        }
        let base = plugin.popupBaseOrigin.flatMap(URL.init(string:))
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><body></body></html>", baseURL: base)
        hosts[plugin.id] = Host(plugin: plugin, webView: web, coordinator: coordinator)
        // onInstalled 的派发移到 Coordinator 收到 addListener("runtime.onInstalled")
        // 的那一刻（确定性）；插件不注册监听器就无需派发——无消费者的
        // evaluate 只是丢进空页。
    }

    private func stop(_ id: UUID) {
        guard let host = hosts.removeValue(forKey: id) else { return }
        host.coordinator.teardown()
        closePorts(pluginID: id)
        backgroundEventListeners.removeValue(forKey: id)
        PluginContextMenuStore.shared.removeAll(pluginID: id)
        Log.userScripts.info("plugin background stopped: \(id.uuidString.prefix(8), privacy: .public)")
    }

    /// 插件被停用/卸载/更新时，其右键菜单项不应再出现。
    func contextMenus(for pageURL: URL?) -> [PluginContextMenuStore.Item] {
        guard let store = AppState.live?.pluginStore else { return [] }
        let enabled = Set(store.plugins.filter { $0.isEnabled && $0.backgroundCode != nil }.map(\.id))
        return PluginContextMenuStore.shared.visibleItems(enabledPluginIDs: enabled)
    }

    /// 插件的包资源目录名（runScripting 读 files[] 用）。
    func resourcesPath(for pluginID: UUID) -> String? {
        guard let store = AppState.live?.pluginStore else { return nil }
        return store.plugins.first(where: { $0.id == pluginID })?.resourcesPath
    }

    /// 插件 background webview（调试/桥 bg-eval 用；无背景宿主 = nil）。
    func backgroundWebview(for pluginID: UUID) -> WKWebView? {
        hosts[pluginID]?.webView
    }

    /// 原生右键菜单点击 → 派发 contextMenus.onClicked 给所属插件的
    /// background webview。
    func contextMenuClick(pluginID: UUID, menuItemID: String,
                          pageURL: URL?, linkURL: URL?, srcURL: URL?, selectionText: String?) {
        let payload: [String: Any?] = [
            "menuItemId": menuItemID,
            "pageUrl": pageURL?.absoluteString,
            "linkUrl": linkURL?.absoluteString,
            "srcUrl": srcURL?.absoluteString,
            "selectionText": selectionText,
        ]
        fire(pluginID: pluginID, event: "contextMenus.onClicked", payload: payload)
        Log.userScripts.info("contextMenus.onClicked dispatched: \(menuItemID, privacy: .public)")
    }

    /// 向某插件的 background webview 派发事件（payload 任意 JSON 形状——
    /// Chrome 多参事件传数组，`_fire` 按位展开；字典/标量单参）。
    func fire(pluginID: UUID, event: String, payload: Any) {
        guard let host = hosts[pluginID] else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        host.webView.evaluateJavaScript(
            "window.__desireExt && window.__desireExt._fire(\(Self.quoted(event)), \(json));",
            in: nil, in: .page, completionHandler: nil)
    }

    /// 广播事件给全部 background 页（tabs.onUpdated 这类全局事件）。
    /// **只投给注册过该事件的插件**——webRequest.onBeforeRequest 每请求
    /// 一发，无差别广播是性能事故；未登记监听的事件 evaluate 进去也无人消费。
    func fireAll(event: String, payload: Any) {
        for id in hosts.keys where backgroundEventListeners[id]?.contains(event) == true {
            fire(pluginID: id, event: event, payload: payload)
        }
    }

    /// webRequest.onBeforeRequest（MV3 观察语义）：网络请求 start 派发。
    func fireWebRequest(details: [String: Any]) {
        fireAll(event: "webRequest.onBeforeRequest", payload: [details])
    }

    /// 背景页登记过的事件名（events/addListener 时记，供 fireAll 过滤）。
    private var backgroundEventListeners: [UUID: Set<String>] = [:]

    func recordEventListener(_ name: String, pluginID: UUID) {
        backgroundEventListeners[pluginID, default: []].insert(name)
    }

    /// storage.onChanged 派发（WebExtensionStore.notifyChange 经观察者进来）。
    func fireStorageChanged(ext: String, changes: [String: Any]) {
        guard UUID(uuidString: ext) != nil else { return }
        fireAll(event: "storage.onChanged", payload: [changes, "local"])
    }

    /// tabs.connect：背景发起的长连接，对端 = 目标 tab 的内容脚本。
    /// 登记端口后向**页面 plugin world** 投递 onConnect（页面端运行时已带
    /// _portConnect 入口；后续消息走既有双端 portMessage 路由）。
    func connectPortToTab(portId: String, name: String, pluginID: UUID,
                          tabWebView: WKWebView, fromBackground: WKWebView?) {
        ports[portId] = PortEntry(pluginID: pluginID, pageWebView: tabWebView,
                                  pageWorld: WebView.pluginWorld(pluginID),
                                  backgroundWebView: fromBackground)
        tabWebView.evaluateJavaScript(
            "window.__desireExt && window.__desireExt._portConnect("
                + Self.quoted(portId) + ", " + Self.quoted(name) + ");",
            in: nil, in: WebView.pluginWorld(pluginID), completionHandler: nil)
    }

    // MARK: - tabs API 宿主侧（页面/背景 handler 共用，防两处漂移）

    static func tabSnapshot(_ t: Tab, index: Int, active: Bool) -> [String: Any] {
        ["id": t.id.uuidString, "index": index,
         "url": t.browser.webView.url?.absoluteString ?? t.urlString,
         "title": t.browser.pageTitle,
         "active": active, "incognito": t.isIncognito, "pinned": t.isPinned]
    }

    static func tabsSnapshot(_ tm: TabManager?) -> [[String: Any]] {
        guard let tm else { return [] }
        return tm.tabs.enumerated().map { index, t in
            tabSnapshot(t, index: index, active: index == tm.selectedIndex)
        }
    }

    static func findTab(_ tm: TabManager?, _ tabIDString: String?) -> (tab: Tab, index: Int)? {
        guard let tm, let s = tabIDString, let id = UUID(uuidString: s),
              let idx = tm.tabs.firstIndex(where: { $0.id == id }) else { return nil }
        return (tm.tabs[idx], idx)
    }

    /// tabs.update {active, url, pinned}。返回错误文案，nil = 成功。
    @discardableResult
    static func updateTab(_ tm: TabManager?, tabIDString: String?, props: [String: Any]) -> String? {
        guard let hit = findTab(tm, tabIDString) else { return "no such tab" }
        if let active = props["active"] as? Bool, active { tm?.selectTab(at: hit.index) }
        if let pinned = props["pinned"] as? Bool { hit.tab.isPinned = pinned }
        if let urlString = props["url"] as? String, !urlString.isEmpty, let u = URL(string: urlString) {
            hit.tab.urlString = urlString
            hit.tab.browser.webView.load(URLRequest(url: u))
        }
        return nil
    }

    /// tabs.reload（tabId 缺省 = 活动标签）。
    static func reloadTab(_ tm: TabManager?, tabIDString: String?) -> String? {
        let hit: (tab: Tab, index: Int)?
        if let tabIDString, !tabIDString.isEmpty, tabIDString != "null" {
            hit = findTab(tm, tabIDString)
        } else if let tm {
            guard !tm.tabs.isEmpty else { return "no such tab" }
            hit = (tm.tabs[tm.selectedIndex], tm.selectedIndex)
        } else {
            hit = nil
        }
        guard let hit else { return "no such tab" }
        hit.tab.browser.webView.reload()
        return nil
    }

    /// 按 tabID 解析 webview（先查登记表，再枚举活窗口——后台标签无登记也找得到）。
    static func webview(for tabID: UUID) -> WKWebView? {
        if let box = shared.tabWebViews.first(where: { $0.tabID == tabID }), let wv = box.webView {
            return wv
        }
        for manager in TabSessionCoordinator.shared.liveManagers() {
            if let t = manager.tabs.first(where: { $0.id == tabID }) {
                return t.browser.webView
            }
        }
        return nil
    }

    /// chrome.scripting.executeScript / insertCSS / removeCSS 宿主侧（页面/
    /// 背景handler 共用）。executeScript 收 code|files[]，insertCSS/removeCSS
    /// 收 css|files[]；文件从插件包资源目录读（PluginResources）。
    /// target.tabId 缺省 = 调用方所在页（fallbackWebView）。求值一律落该插件
    /// 的 per-plugin world——内容脚本世界 chrome.* 可用，DOM 共享（insertCSS
    /// 建的 <style> 直接落页面）。
    enum ScriptingOp { case execute, insert, remove }

    static func runScripting(details: [String: Any], pluginID: UUID, resourcesPath: String?,
                             op: ScriptingOp, fallbackWebView: WKWebView?,
                             completion: @escaping @MainActor (Any?, String?) -> Void) {
        let target = details["target"] as? [String: Any]
        let webview: WKWebView?
        if let tabIDString = target?["tabId"] as? String, let tabID = UUID(uuidString: tabIDString) {
            guard let resolved = Self.webview(for: tabID) else {
                completion(nil, "no such tab")
                return
            }
            webview = resolved
        } else {
            webview = fallbackWebView
        }
        guard let webview else {
            completion(nil, "scripting requires target.tabId or a page context")
            return
        }
        do {
            let code: String
            if let files = details["files"] as? [String], !files.isEmpty {
                let parts = try files.map {
                    try PluginResources.readTextFile(resourcesPath: resourcesPath, relativePath: $0)
                }
                code = parts.joined(separator: "\n;\n")
            } else if op != .execute, let css = details["css"] as? String, !css.isEmpty {
                code = css
            } else if let js = details["code"] as? String, !js.isEmpty {
                code = js
            } else {
                let expectation = op == .execute ? "code or files" : "css or files"
                completion(nil, "scripting.\(op == .execute ? "executeScript" : (op == .insert ? "insertCSS" : "removeCSS")) requires \(expectation)")
                return
            }
            let finalJS: String
            switch op {
            case .execute:
                // 与 PluginStore.inject 同理：world 的 user script 是 webview
                // 定格的，插件后装时 world 里没有 chrome.*——幂等前置运行时。
                let runtime = UserScriptLoader.load("webext-api")
                finalJS = PluginI18N.prologue(resourcesPath: resourcesPath)
                    + (runtime.isEmpty ? "" : runtime + "\n") + code
            case .insert:
                // 标记 + 尾值固定：appendChild 返回 DOM 元素会作为求值结果
                // 一路传进 reply 的 JSONSerialization（ObjC 异常 abort，实测）。
                finalJS = "(function(){var s=document.createElement('style');"
                    + "s.setAttribute('data-desire-ext-css','1');s.textContent="
                    + JSString.literal(code) + ";document.head.appendChild(s);})();'';"
            case .remove:
                // removeCSS：按 css 内容精确匹配本插件标记的 style 元素删除。
                finalJS = "(function(){var els=document.querySelectorAll('style[data-desire-ext-css]');"
                    + "var css=" + JSString.literal(code) + ";"
                    + "for(var i=0;i<els.length;i++){if(els[i].textContent===css&&els[i].parentNode){els[i].parentNode.removeChild(els[i]);}}})();'';"
            }
            webview.evaluateJavaScript(finalJS, in: nil, in: WebView.pluginWorld(pluginID)) { result in
                switch result {
                case .success(let value): completion(value, nil)
                case .failure(let error): completion(nil, error.localizedDescription)
                }
            }
        } catch {
            completion(nil, error.localizedDescription)
        }
    }

    // MARK: - alarms（chrome.alarms 插件级定时器）

    struct Alarm: Codable {
        let name: String
        var scheduledAt: Date
        var periodInMinutes: Double?
        let pluginID: UUID
    }

    /// 插件 alarms 表（key = pluginID|name）+ 到期检查 Timer。
    /// DiskStore 持久化：app 重启后恢复重排（否则周期 alarm 跨重启丢失）。
    private var alarms: [String: Alarm] = [:]
    private var alarmTimers: [String: Timer] = [:]
    private static let alarmsKey = "plugin.alarms"

    private func saveAlarms() {
        DiskStore.save(Array(alarms.values), key: Self.alarmsKey)
    }

    /// 插件停用时清它的 alarms（stop 调用）。
    func clearAlarms(pluginID: UUID) {
        let prefix = pluginID.uuidString + "|"
        for key in alarms.keys where key.hasPrefix(prefix) {
            alarmTimers[key]?.invalidate()
            alarmTimers.removeValue(forKey: key)
            alarms.removeValue(forKey: key)
        }
    }

    func setAlarm(pluginID: UUID, name: String, when: Date, periodInMinutes: Double?) {
        let key = pluginID.uuidString + "|" + name
        alarms[key] = Alarm(name: name, scheduledAt: when,
                            periodInMinutes: periodInMinutes, pluginID: pluginID)
        saveAlarms()
        scheduleAlarm(pluginID: pluginID, name: name, when: when, periodInMinutes: periodInMinutes)
    }

    func clearAlarm(pluginID: UUID, name: String) {
        let key = pluginID.uuidString + "|" + name
        alarmTimers[key]?.invalidate()
        alarmTimers.removeValue(forKey: key)
        alarms.removeValue(forKey: key)
        saveAlarms()
    }

    func alarmsFor(pluginID: UUID) -> [[String: Any]] {
        return alarms.filter { $0.key.hasPrefix(pluginID.uuidString) }
            .values.map { ["name": $0.name,
                           "scheduledAt": $0.scheduledAt.timeIntervalSince1970] as [String: Any] }
    }

    /// alarms 到期 → 向该插件 background 页派发 alarms.onAlarm 事件。
    private func scheduleAlarm(pluginID: UUID, name: String, when: Date, periodInMinutes: Double?) {
        let interval = max(1, when.timeIntervalSinceNow)
        let key = pluginID.uuidString + "|" + name
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fire(pluginID: pluginID, event: "alarms.onAlarm", payload: ["name": name])
                // 周期性 alarm：重新调度。
                if let period = periodInMinutes, period > 0 {
                    let next = Date().addingTimeInterval(period * 60)
                    self.alarms[key]?.scheduledAt = next
                    self.scheduleAlarm(pluginID: pluginID, name: name, when: next, periodInMinutes: period)
                } else {
                    self.alarms.removeValue(forKey: key)
                    self.alarmTimers.removeValue(forKey: key)
                }
            }
        }
        alarmTimers[key] = timer
    }

    // MARK: - 消息传递（runtime.sendMessage / tabs.sendMessage 路由）

    // MARK: - Port 长连接（runtime.connect ↔ onConnect 路由）

    /// 端口表（key = 全局唯一 portId）。页面端与 background 端各持一个同名
    /// Port 对象，postMessage/disconnect 按“发送方是哪一端”投给另一端。
    /// 页面端求值必须落回它注册时的 content-script world（extensionWorld 或
    /// per-plugin world，见 WebView.pluginWorld）——连接登记时把 world 一起存下。
    private struct PortEntry {
        let pluginID: UUID
        weak var pageWebView: WKWebView?
        let pageWorld: WKContentWorld
        weak var backgroundWebView: WKWebView?
    }
    private var ports: [String: PortEntry] = [:]

    /// 页面端 connect（WebView 消息路径）：登记端口并通知 background 页 onConnect。
    func openPort(portId: String, name: String, pluginID: UUID,
                  pageWebView: WKWebView, pageWorld: WKContentWorld) {
        ports[portId] = PortEntry(pluginID: pluginID, pageWebView: pageWebView,
                                  pageWorld: pageWorld,
                                  backgroundWebView: hosts[pluginID]?.webView)
        if let bg = hosts[pluginID]?.webView {
            bg.evaluateJavaScript(
                "window.__desireExt && window.__desireExt._portConnect("
                    + Self.quoted(portId) + ", " + Self.quoted(name) + ");",
                in: nil, in: .page, completionHandler: nil)
        }
    }

    /// background 端 connect（background 页自己 runtime.connect——对端内容脚本
    /// 尚未连接，仅登记；页面侧调 connect 后消息才开始有去处）。
    func openPortFromBackground(portId: String, pluginID: UUID, backgroundWebView: WKWebView) {
        ports[portId] = PortEntry(pluginID: pluginID, pageWebView: nil,
                                  pageWorld: .page, backgroundWebView: backgroundWebView)
    }

    /// 任一端 postMessage → 投给另一端。
    func portMessage(portId: String, from sender: WKWebView, payload: Any) {
        guard let entry = ports[portId] else { return }
        let js = "window.__desireExt && window.__desireExt._portMessage("
            + Self.quoted(portId) + ", " + quotedJSON(payload) + ");"
        if sender === entry.pageWebView {
            entry.backgroundWebView?.evaluateJavaScript(
                js, in: nil, in: .page, completionHandler: nil)
        } else {
            entry.pageWebView?.evaluateJavaScript(
                js, in: nil, in: entry.pageWorld, completionHandler: nil)
        }
    }

    /// 任一端 disconnect → 通知另一端并拆表。
    func closePort(portId: String, from sender: WKWebView) {
        guard let entry = ports[portId] else { return }
        ports.removeValue(forKey: portId)
        let js = "window.__desireExt && window.__desireExt._portDisconnected(" + Self.quoted(portId) + ");"
        if sender === entry.pageWebView {
            entry.backgroundWebView?.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
        } else {
            entry.pageWebView?.evaluateJavaScript(js, in: nil, in: entry.pageWorld, completionHandler: nil)
        }
    }

    /// 插件停用/卸载：撕掉它的全部端口（两端都通知；插件自己的 webview 正在
    /// 拆除，多收一条 no-op 求值无害）。
    func closePorts(pluginID: UUID) {
        for (portId, entry) in ports where entry.pluginID == pluginID {
            ports.removeValue(forKey: portId)
            let js = "window.__desireExt && window.__desireExt._portDisconnected(" + Self.quoted(portId) + ");"
            entry.backgroundWebView?.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
            entry.pageWebView?.evaluateJavaScript(js, in: nil, in: entry.pageWorld, completionHandler: nil)
        }
    }

    /// 回复路由表：replyId → 等待回复的 webview + **它的 content-script world**。
    /// 页面侧插件活在 extensionWorld / per-plugin world——不指定 world 的求值
    /// 落在默认 page world，那里没有 __desireExt，回复会静默蒸发（实测）。
    private struct PendingReply {
        weak var webView: WKWebView?
        let world: WKContentWorld
    }
    private var pendingReplies: [String: PendingReply] = [:]

    /// 页面 → background：把消息投给指定插件的 background 页 onMessage。
    /// 无人监听或插件无 background 时立即回 "noListener"。
    func deliverToBackground(pluginID: UUID, message: Any, sender: [String: Any],
                             replyId: String, replyWebView: WKWebView,
                             replyWorld: WKContentWorld) {
        guard let host = hosts[pluginID] else {
            replyNoListener(replyId, to: replyWebView, world: replyWorld)
            return
        }
        pendingReplies[replyId] = PendingReply(webView: replyWebView, world: replyWorld)
        Log.userScripts.info("deliverToBackground: \(pluginID.uuidString.prefix(8), privacy: .public) replyId=\(replyId, privacy: .public)")
        var parts: [String] = ["window.__desireExt && window.__desireExt._runtimeMessage("]
        parts.append(Self.quoted(replyId))
        parts.append(", ")
        parts.append(quotedJSON(message))
        parts.append(", ")
        parts.append(quotedJSON(sender))
        parts.append(");")
        let js = parts.joined()
        // background 页的 chrome.* 在 .page 世界（与 popup 同理），必须指定 world。
        host.webView.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
    }

    /// background → 页面：把消息投给指定 tab 的页面世界 onMessage。
    /// 找不到该 tab 或该页未注册监听（页面脚本会在无监听时回 noListener）→ 回 noListener 给 background。
    func deliverToTab(tabID: UUID, pluginID: UUID, message: Any, sender: [String: Any],
                      replyId: String, fromWebView: WKWebView, fromWorld: WKContentWorld) {
        guard let box = tabWebViews.first(where: { $0.tabID == tabID }), let web = box.webView else {
            replyNoListener(replyId, to: fromWebView, world: fromWorld)
            return
        }
        pendingReplies[replyId] = PendingReply(webView: fromWebView, world: fromWorld)
        let js = "window.__desireExt && window.__desireExt._tabsMessage("
            + Self.quoted(replyId) + ", " + quotedJSON(message) + ", " + quotedJSON(sender) + ");"
        // 内容脚本活在 per-plugin world（PluginStore.inject 同款 world）——
        // 默认 page world 里没有 __desireExt，求值会静默丢失。
        web.evaluateJavaScript(js, in: nil, in: WebView.pluginWorld(pluginID), completionHandler: nil)
    }

    /// 回复回投：把 onMessage 的回复送回发起方（按 replyId 查路由表）。
    func deliverReply(replyId: String, ok: Bool, reply: Any?, noListener: Bool) {
        Log.userScripts.info("deliverReply: \(replyId, privacy: .public) ok=\(ok, privacy: .public)")
        guard let target = pendingReplies.removeValue(forKey: replyId),
              let web = target.webView else { return }
        let replyJSON = quotedJSON(reply ?? NSNull())
        let js = "window.__desireExt && window.__desireExt._resolveReply(\(Self.quoted(replyId)), \(ok), \(replyJSON), \(noListener))"
        web.evaluateJavaScript(js, in: nil, in: target.world, completionHandler: nil)
    }

    /// 注册 tab → webview 映射（内容脚本插件注入页面时登记，供 tabs.sendMessage 寻址）。
    func registerTabWebview(_ tabID: UUID, webView: WKWebView) {
        tabWebViews.removeAll { $0.tabID == tabID }
        tabWebViews.append(TabWebBox(tabID: tabID, webView: webView))
        if tabWebViews.count > 50 { tabWebViews.removeFirst(tabWebViews.count - 50) }
    }

    private struct TabWebBox { let tabID: UUID; weak var webView: WKWebView? }
    private var tabWebViews: [TabWebBox] = []

    private func replyNoListener(_ replyId: String, to webview: WKWebView, world: WKContentWorld) {
        webview.evaluateJavaScript(
            "window.__desireExt && window.__desireExt._resolveReply(\(Self.quoted(replyId)), false, null, true)",
            in: nil, in: world, completionHandler: nil)
    }

    private func quotedJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let str = String(data: data, encoding: .utf8) else { return "null" }
        return str
    }

    private static func quoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// PluginStore 变更 → 对账（只接一次）。
    private func wireStoreChanges(_ store: PluginStore) {
        guard !wired else { return }
        wired = true
        store.onPluginsChanged = { [weak self] in
            self?.syncAll()
        }
    }

    // MARK: - RPC 宿主（background/popup webview 的 chrome.* 后端，收口共用）

    /// 宿主 RPC 的**唯一实现**：背景 Coordinator 与 popup Coordinator 全部
    /// 转发到这里（2026-10-02 审查收口——此前 popup 只有 5 个 case、cookies
    /// 背景缺失，三面 handler 各自漂移）。页面 handler 保持独立（窗口上下文
    /// 与回程 world 语义不同）。
    /// - fallbackWebView：scripting/port 的默认目标（背景页/popup 自身）。
    /// - reply：回包求值进来源 webview 的 .page world（两处 coordinator 同款）。
    static func dispatchHostRPC(ns: String, fn: String, args: [Any], pluginID: UUID,
                                sourceWebView: WKWebView?,
                                reply: @escaping @MainActor (Any?, String?) -> Void) async {
        switch (ns, fn) {
        case ("storage", "get"):
            reply(WebExtensionStore.get(keys: args.first, ext: pluginID.uuidString), nil)
        case ("storage", "set"):
            guard let items = args.first as? [String: Any] else {
                reply(nil, "storage.set requires an object")
                return
            }
            WebExtensionStore.set(items: items, ext: pluginID.uuidString)
            // storage.onChanged：updated 全量带旧值查询（见 notifyChange）。
            WebExtensionStore.notifyChange(ext: pluginID.uuidString, removed: [:], updated: items)
            reply([:], nil)
        case ("storage", "remove"):
            let keys = (args.first as? [Any])?.compactMap { $0 as? String } ?? []
            var removed: [String: Any] = [:]
            for key in keys {
                removed[key] = WebExtensionStore.get(keys: [key], ext: pluginID.uuidString)
            }
            WebExtensionStore.remove(keys: keys, ext: pluginID.uuidString)
            WebExtensionStore.notifyChange(ext: pluginID.uuidString, removed: removed, updated: [:])
            reply([:], nil)
        case ("storage", "clear"):
            let old = WebExtensionStore.get(keys: nil, ext: pluginID.uuidString)
            WebExtensionStore.clear(ext: pluginID.uuidString)
            if !old.isEmpty {
                WebExtensionStore.notifyChange(ext: pluginID.uuidString, removed: old, updated: [:])
            }
            reply([:], nil)
        case ("notifications", "create"):
            WebExtensionStore.createNotification(args.first as? [String: Any] ?? [:]) { result in
                reply(result, nil)
            }
        case ("notifications", "clear"):
            let id = args.first as? String ?? ""
            WebExtensionStore.clearNotifications(id.isEmpty ? [] : [id]) { result in
                reply(result, nil)
            }
        case ("contextMenus", "create"):
            guard let props = args.first as? [String: Any],
                  let menuID = (props["id"] as? String) ?? (props["id"] as? NSNumber)?.stringValue else {
                reply(nil, "contextMenus.create requires props.id")
                return
            }
            let title = props["title"] as? String ?? menuID
            let contexts = (props["contexts"] as? [String]) ?? ["page"]
            PluginContextMenuStore.shared.upsert(
                pluginID: pluginID, menuID: menuID, title: title, contexts: contexts)
            reply(menuID, nil)
        case ("contextMenus", "remove"):
            if let menuID = args.first as? String {
                PluginContextMenuStore.shared.remove(pluginID: pluginID, menuID: menuID)
            }
            reply([:], nil)
        case ("contextMenus", "removeAll"):
            PluginContextMenuStore.shared.removeAll(pluginID: pluginID)
            reply([:], nil)
        case ("runtime", "sendMessageToTab"):
            Log.userScripts.info("host rpc: sendMessageToTab \(args.count, privacy: .public) args")
            // background/popup → 页面：tabId 寻址投递，回复经 sendReply 回本页。
            guard args.count >= 2,
                  let tabIDString = args[0] as? String,
                  let tabUUID = UUID(uuidString: tabIDString) else {
                reply(nil, "sendMessageToTab requires (tabId, message)")
                return
            }
            // 路由 id 由 JS 生成上送（args[2]），回包按它找回原 Promise。
            let routedReplyId = (args.count > 2 ? args[2] as? String : nil)
                ?? "tab-\(UUID().uuidString)"
            guard let fromWeb = sourceWebView else {
                reply(nil, "no webview")
                return
            }
            PluginBackgroundRuntime.shared.deliverToTab(
                tabID: tabUUID, pluginID: pluginID,
                message: args[1], sender: ["fromBackground": true],
                replyId: routedReplyId,
                fromWebView: fromWeb, fromWorld: .page)
            reply([:], nil)
        case ("runtime", "sendReply"):
            // 页面侧 onMessage 的回复回投（background 发起的 sendMessageToTab）。
            guard args.count >= 2, let envelope = args[1] as? [String: Any] else {
                reply(nil, "sendReply requires (replyId, envelope)")
                return
            }
            PluginBackgroundRuntime.shared.deliverReply(
                replyId: args[0] as? String ?? "",
                ok: (envelope["ok"] as? Bool) == true,
                reply: envelope["reply"] as Any,
                noListener: (envelope["noListener"] as? Bool) == true)
            reply([:], nil)
        case ("alarms", "create"):
            guard let a = args.first as? [String: Any],
                  let name = a["name"] as? String, !name.isEmpty else {
                reply(nil, "alarms.create requires {name, ...}")
                return
            }
            let when: Date
            if let mins = a["periodInMinutes"] as? Double, mins > 0 {
                when = Date().addingTimeInterval(mins * 60)
            } else if let mins = a["delayInMinutes"] as? Double, mins > 0 {
                when = Date().addingTimeInterval(mins * 60)
            } else {
                when = Date().addingTimeInterval(60)
            }
            PluginBackgroundRuntime.shared.setAlarm(pluginID: pluginID, name: name,
                                                    when: when,
                                                    periodInMinutes: a["periodInMinutes"] as? Double)
            reply([:], nil)
        case ("alarms", "clear"):
            let name = args.first as? String ?? ""
            PluginBackgroundRuntime.shared.clearAlarm(pluginID: pluginID, name: name)
            reply(name.isEmpty ? "cleared all" : "cleared", nil)
        case ("alarms", "clearAll"):
            PluginBackgroundRuntime.shared.clearAlarms(pluginID: pluginID)
            reply([:], nil)
        case ("alarms", "getAll"):
            reply(PluginBackgroundRuntime.shared.alarmsFor(pluginID: pluginID), nil)
        case ("alarms", "get"):
            let name = args.first as? String ?? ""
            reply(PluginBackgroundRuntime.shared.alarmsFor(pluginID: pluginID)
                .first(where: { ($0["name"] as? String) == name }) ?? NSNull(), nil)
        case ("action", "setBadgeText"):
            // Desire 工具栏角标（固定图标上渲染；空串 = 清除）。
            let badgeText = (args.first as? [String: Any])?["text"] as? String ?? ""
            if let app = AppState.live {
                if badgeText.isEmpty {
                    app.pluginStore.badges.removeValue(forKey: pluginID)
                } else {
                    app.pluginStore.badges[pluginID] = String(badgeText.prefix(4))
                }
            }
            reply([:], nil)
        case ("action", "getBadgeText"):
            let currentBadge = AppState.live?.pluginStore.badges[pluginID] ?? ""
            reply(["text": currentBadge], nil)
        case ("action", "setTitle"):
            reply([:], nil)
        case ("windows", "getAll"):
            let managers = TabSessionCoordinator.shared.liveManagers()
            var wins: [[String: Any]] = []
            for (wi, manager) in managers.enumerated() {
                var tabsList: [[String: Any]] = []
                for (tidx, t) in manager.tabs.enumerated() {
                    tabsList.append([
                        "id": t.id.uuidString, "index": tidx,
                        "url": t.browser.webView.url?.absoluteString ?? t.urlString,
                        "title": t.browser.pageTitle,
                    ])
                }
                wins.append(["id": wi, "tabs": tabsList])
            }
            reply(wins, nil)
        case ("windows", "create"):
            if let url = (args.first as? [String: Any])?["url"] as? String, !url.isEmpty {
                TabSessionCoordinator.shared.activeTabManager?.addTab(url: url)
                reply([:], nil)
            } else {
                reply(nil, "windows.create requires {url}")
            }
        case ("downloads", "download"):
            guard let a = args.first as? [String: Any],
                  let urlString = a["url"] as? String, !urlString.isEmpty else {
                reply(nil, "downloads.download requires url")
                return
            }
            let filename = a["filename"] as? String ?? URL(string: urlString)?.lastPathComponent ?? "download"
            if let app = AppState.live {
                app.downloadStore.startURLSessionDownload(
                    sourceURL: URL(string: urlString) ?? URL(fileURLWithPath: "/dev/null"),
                    filename: filename, isPrivate: false)
            }
            reply([:], nil)
        case ("downloads", "search"):
            let rows = AppState.live?.downloadStore.downloads.map { d -> [String: Any] in
                ["filename": d.filename, "state": d.state.rawValue,
                 "bytes": d.downloadedBytes] as [String: Any]
            } ?? []
            reply(rows, nil)
        case ("port", "connect"):
            // background/popup 页发起（对端内容脚本尚未连接，仅登记）。
            if args.count >= 2, let bgPortId = args[0] as? String, let bgWeb = sourceWebView {
                PluginBackgroundRuntime.shared.openPortFromBackground(
                    portId: bgPortId, pluginID: pluginID, backgroundWebView: bgWeb)
            }
            reply([:], nil)
        case ("port", "postMessage"):
            guard let msgPortId = args.first as? String, let fromWeb = sourceWebView else {
                reply(nil, "port.postMessage requires portId")
                return
            }
            PluginBackgroundRuntime.shared.portMessage(
                portId: msgPortId, from: fromWeb,
                payload: args.count > 1 ? args[1] : NSNull())
            reply([:], nil)
        case ("port", "disconnect"):
            if let msgPortId = args.first as? String, let fromWeb = sourceWebView {
                PluginBackgroundRuntime.shared.closePort(portId: msgPortId, from: fromWeb)
            }
            reply([:], nil)
        case ("declarativeNetRequest", "updateRules"):
            // 规则信封从消息体恢复成 JSON 再 decode（args 已是 [Any]）。
            guard let optionsData = try? JSONSerialization.data(withJSONObject: args.first ?? [:], options: []),
                  let options = try? JSONDecoder().decode(DNROptions.self, from: optionsData) else {
                reply(nil, "updateRules requires {addRules, removeRuleIds}")
                return
            }
            let session = (args.count > 1 && (args[1] as? Bool) == true)
            do {
                try PluginDNRStore.shared.updateRules(
                    pluginID: pluginID, add: options.addRules ?? [],
                    removeIds: options.removeRuleIds ?? [], session: session)
                reply([:], nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        case ("declarativeNetRequest", "getRules"):
            let session = (args.first as? Bool) == true
            let dnrRules = PluginDNRStore.shared.getRules(pluginID: pluginID, session: session)
            // JSONSerialization 不认 Swift struct 数组（DNRRule）——
            // 经 JSONEncoder 往返成字典，直接塞会 isValid=false → null。
            let payload = dnrRules.map { rule -> [String: Any] in
                guard let data = try? JSONEncoder().encode(rule),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ["id": rule.id]
                }
                return object
            }
            reply(["rules": payload], nil)
        case ("tabs", "query"):
            // background/popup 无窗口上下文——查活动窗口的标签快照（与桥同源）。
            reply(PluginBackgroundRuntime.tabsSnapshot(TabSessionCoordinator.shared.activeTabManager), nil)
        case ("tabs", "create"):
            if let props = args.first as? [String: Any],
               let url = props["url"] as? String, !url.isEmpty {
                let tm = TabSessionCoordinator.shared.activeTabManager
                let previouslySelected = tm?.selectedIndex ?? 0
                tm?.addTab(url: url)
                // Chrome 语义：{active: false} 不切走（addTab 默认选中新建）。
                if (props["active"] as? Bool) == false, let tm, tm.selectedIndex != previouslySelected {
                    tm.selectTab(at: previouslySelected)
                }
                reply([:], nil)
            } else {
                reply(nil, "tabs.create requires {url}")
            }
        case ("tabs", "remove"):
            guard let tm = TabSessionCoordinator.shared.activeTabManager else {
                reply(nil, "no active window")
                return
            }
            let ids: [String]
            if let single = args.first as? String { ids = [single] }
            else if let many = args.first as? [String] { ids = many }
            else { ids = [] }
            guard !ids.isEmpty else {
                reply(nil, "tabs.remove requires id(s)")
                return
            }
            // 逐个按 id 现查 index（删一个 index 全动，快照索引会错位）。
            for idString in ids {
                if let idx = tm.tabs.firstIndex(where: { $0.id.uuidString == idString }) {
                    tm.closeTab(at: idx)
                }
            }
            reply([:], nil)
        case ("tabs", "update"):
            guard let props = args.count > 1 ? args[1] as? [String: Any] : nil else {
                reply(nil, "tabs.update requires (tabId, props)")
                return
            }
            if let err = PluginBackgroundRuntime.updateTab(TabSessionCoordinator.shared.activeTabManager,
                                        tabIDString: args.first as? String, props: props) {
                reply(nil, err)
            } else {
                reply([:], nil)
            }
        case ("tabs", "get"):
            if let hit = PluginBackgroundRuntime.findTab(TabSessionCoordinator.shared.activeTabManager,
                                      args.first as? String) {
                reply(PluginBackgroundRuntime.tabSnapshot(hit.tab, index: hit.index,
                                       active: hit.index == TabSessionCoordinator.shared.activeTabManager?.selectedIndex), nil)
            } else {
                reply(nil, "no such tab")
            }
        case ("tabs", "reload"):
            if let err = PluginBackgroundRuntime.reloadTab(TabSessionCoordinator.shared.activeTabManager,
                                        tabIDString: args.first as? String) {
                reply(nil, err)
            } else {
                reply([:], nil)
            }
        case ("tabs", "connect"):
            // 背景发起的长连接，对端 = 该 tab 的内容脚本（runtime.onConnect 收）。
            guard args.count >= 2, let tabIDString = args[0] as? String,
                  let tabUUID = UUID(uuidString: tabIDString),
                  let portId = args[1] as? String else {
                reply(nil, "tabs.connect requires (tabId, portId)")
                return
            }
            let name = (args.count > 2 ? args[2] as? String : nil) ?? ""
            guard let target = webview(for: tabUUID) else {
                reply(nil, "no such tab")
                return
            }
            PluginBackgroundRuntime.shared.connectPortToTab(
                portId: portId, name: name, pluginID: pluginID,
                tabWebView: target, fromBackground: sourceWebView)
            reply([:], nil)
        case ("scripting", "executeScript"), ("scripting", "insertCSS"), ("scripting", "removeCSS"):
            guard let details = args.first as? [String: Any] else {
                reply(nil, "scripting requires details")
                return
            }
            guard let sourceWeb = sourceWebView else {
                reply(nil, "no webview")
                return
            }
            let op: ScriptingOp = fn == "executeScript" ? .execute : (fn == "insertCSS" ? .insert : .remove)
            PluginBackgroundRuntime.runScripting(
                details: details, pluginID: pluginID,
                resourcesPath: PluginBackgroundRuntime.shared.resourcesPath(for: pluginID),
                op: op, fallbackWebView: sourceWeb) { value, error in
                reply(value, error)
            }
        case ("cookies", "getAll"), ("cookies", "get"), ("cookies", "set"), ("cookies", "remove"):
            // 背景/popup 无标签上下文——默认（非无痕）cookie 存储。
            await Self.dispatchCookies(fn: fn, args: args, reply: reply)
        default:
            reply(nil, "background runtime: unknown \(ns).\(fn)")
        }
    }

    /// allCookies 的 async 包装（SDK 回调式 API；allCookies() 属性会触发
    /// "consider using asynchronous alternative function" 警告）。
    private static func allCookies(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// cookies 三件套（默认存储版；页面 handler 用所在标签的存储，含无痕）。
    private static func dispatchCookies(fn: String, args: [Any],
                                        reply: @escaping @MainActor (Any?, String?) -> Void) async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        switch fn {
        case "getAll":
            let filterURL = (args.first as? [String: Any])?["url"]
                .flatMap { $0 as? String }.flatMap { URL(string: $0) }
            let cookies = await Self.allCookies(cookieStore)
            var list: [[String: Any]] = []
            for c in cookies {
                if let fu = filterURL {
                    guard c.domain.hasSuffix(fu.host ?? "#") || fu.host?.hasSuffix(c.domain) == true else { continue }
                }
                list.append(["domain": c.domain, "name": c.name, "value": c.value,
                             "path": c.path, "secure": c.isSecure])
            }
            reply(list, nil)
        case "get":
            guard let details = args.first as? [String: Any],
                  let name = details["name"] as? String else {
                reply(nil, "cookies.get requires name")
                return
            }
            let cookies = await Self.allCookies(cookieStore)
            let hit = cookies.first { $0.name == name }
            reply(hit.map { ["domain": $0.domain, "name": $0.name,
                             "value": $0.value, "path": $0.path] } ?? NSNull(), nil)
        case "remove":
            guard let rmDetails = args.first as? [String: Any],
                  let rmName = rmDetails["name"] as? String else {
                reply(nil, "cookies.remove requires name")
                return
            }
            let allCookies = await Self.allCookies(cookieStore)
            for cookie in allCookies where cookie.name == rmName {
                // delete 的同步/async 重载决议歧义（两条互斥警告）——
                // 显式走 completion 形式。
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    cookieStore.delete(cookie) { cont.resume() }
                }
            }
            reply([:], nil)
        default: // set
            guard let details = args.first as? [String: Any],
                  let name = details["name"] as? String,
                  let value = details["value"] as? String else {
                reply(nil, "cookies.set requires name/value")
                return
            }
            // Chrome 语义：domain 可省——从 url 的 host 推导。
            let domain: String
            if let explicit = details["domain"] as? String, !explicit.isEmpty {
                domain = explicit
            } else if let urlString = details["url"] as? String,
                      let host = URL(string: urlString)?.host {
                domain = host
            } else {
                reply(nil, "cookies.set requires url or domain")
                return
            }
            let props = [HTTPCookiePropertyKey.domain: domain,
                         HTTPCookiePropertyKey.name: name,
                         HTTPCookiePropertyKey.value: value,
                         HTTPCookiePropertyKey.path: details["path"] as? String ?? "/",
                         HTTPCookiePropertyKey.secure: "1"]
            if let cookie = HTTPCookie(properties: props) {
                await cookieStore.setCookie(cookie)
                reply([:], nil)
            } else {
                reply(nil, "cookie construction failed")
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let pluginID: UUID
        private var tornDown = false

        init(pluginID: UUID) {
            self.pluginID = pluginID
        }

        func teardown() {
            tornDown = true
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "desireExt" else { return }
            Task { @MainActor in
                await self.handle(message)
            }
        }

        private func handle(_ message: WKScriptMessage) async {
            guard !tornDown else { return }
            guard let dict = message.body as? [String: Any],
                  let ns = dict["ns"] as? String,
                  let fn = dict["fn"] as? String else { return }
            let id = dict["id"] as? Int
            let args = dict["args"] as? [Any] ?? []

            func reply(_ payload: Any?, error: String? = nil) {
                guard let id else { return }
                let json: String
                if let error {
                    let escaped = error
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    json = "\"\(escaped)\""
                } else if let payload {
                    // **顶层必须是数组/字典**：JSONSerialization 对标量顶层抛的
                    // 是 ObjC 异常，try? 拦不住（进程直接 FAULT——storage.get
                    // 返回字符串、contextMenus.create 返回菜单 id 都踩）。
                    // 标量手动字符串化，容器才走 JSONSerialization。
                    switch payload {
                    case let scalar as String:
                        json = JSString.literal(scalar)
                    case let bool as Bool:
                        json = bool ? "true" : "false"
                    case let number as NSNumber:
                        json = number.stringValue
                    default:
                        if JSONSerialization.isValidJSONObject(payload),
                           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) {
                            json = str
                        } else {
                            // 非 JSON 容器（DOM 节点等 Objective-C 对象）：
                            // dataWithJSONObject 对它抛的是 ObjC 异常，try?
                            // 拦不住、进程直接 abort——必须先 isValid。
                            json = "null"
                        }
                    }
                } else {
                    json = "null"
                }
                message.webView?.evaluateJavaScript(
                    "window.__desireExt && window.__desireExt._resolve(\(id), \(error == nil), \(json))",
                    in: nil, in: .page, completionHandler: nil)
            }

            switch (ns, fn) {
            case ("events", "addListener"):
                // background webview 是事件的唯一接收方——无需登记，
                // 宿主派发时直接 evaluate 进来。**但 fireAll 按登记过滤**
                //（webRequest.onBeforeRequest 每请求一发，不登记会全插件
                // 广播成性能事故），这里记一笔。
                if let name = args.first as? String {
                    PluginBackgroundRuntime.shared.recordEventListener(name, pluginID: pluginID)
                }
                // **onInstalled 确定性触发**：页面侧注册监听这一刻桥会上报，
                // 收到即派发——此前 300ms 延迟是启发式，atDocumentEnd 的
                // background 代码慢一点监听器就还没注册、事件凭空丢失。
                if let name = args.first as? String, name == "runtime.onInstalled" {
                    // 消息自带 webView（即本插件的 background 页），直接回注。
                    _ = try? await message.webView?.evaluateJavaScript(
                        "window.__desireExt && window.__desireExt._fire(\"runtime.onInstalled\", {\"reason\":\"install\"});")
                    Log.userScripts.info("plugin background started: \(self.pluginID.uuidString.prefix(8), privacy: .public)")
                }
                reply([:])
            default:
                // 宿主 RPC 收口（2026-10-02 审查）：背景/来源页面之外的
                // 全部 case 与 **popup handler 共用同一份实现**——此前 popup
                // 只有 5 个 case、cookies 背景缺失，三面各自漂移。
                await PluginBackgroundRuntime.dispatchHostRPC(
                    ns: ns, fn: fn, args: args, pluginID: pluginID,
                    sourceWebView: message.webView) { payload, error in
                    reply(payload, error: error)
                }
            }
        }
    }
}
