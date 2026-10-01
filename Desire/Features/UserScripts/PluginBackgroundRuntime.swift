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
    private override init() {}

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
        PluginContextMenuStore.shared.removeAll(pluginID: id)
        Log.userScripts.info("plugin background stopped: \(id.uuidString.prefix(8), privacy: .public)")
    }

    /// 插件被停用/卸载/更新时，其右键菜单项不应再出现。
    func contextMenus(for pageURL: URL?) -> [PluginContextMenuStore.Item] {
        guard let store = AppState.live?.pluginStore else { return [] }
        let enabled = Set(store.plugins.filter { $0.isEnabled && $0.backgroundCode != nil }.map(\.id))
        return PluginContextMenuStore.shared.visibleItems(enabledPluginIDs: enabled)
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

    /// 向某插件的 background webview 派发事件。
    // MARK: - 消息传递（runtime.sendMessage / tabs.sendMessage 路由）

    /// 回复路由表：replyId → 等待回复的 webview（发起方页面）。
    private var pendingReplies: [String: WKWebView] = [:]

    /// 页面 → background：把消息投给指定插件的 background 页 onMessage。
    /// 无人监听或插件无 background 时立即回 "noListener"。
    func deliverToBackground(pluginID: UUID, message: Any, sender: [String: Any],
                             replyId: String, replyWebView: WKWebView) {
        guard let host = hosts[pluginID] else {
            replyNoListener(replyId, to: replyWebView)
            return
        }
        pendingReplies[replyId] = replyWebView
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
                      replyId: String, fromWebView: WKWebView) {
        guard let box = tabWebViews.first(where: { $0.tabID == tabID }), let web = box.webView else {
            fromWebView.evaluateJavaScript(
                "window.__desireExt && window.__desireExt._resolveReply(\(Self.quoted(replyId)), false, null, true)",
                completionHandler: nil)
            return
        }
        pendingReplies[replyId] = fromWebView
        let js = "window.__desireExt && window.__desireExt._tabsMessage("
            + Self.quoted(replyId) + ", " + quotedJSON(message) + ", " + quotedJSON(sender) + ");"
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 回复回投：把 onMessage 的回复送回发起方（按 replyId 查路由表）。
    func deliverReply(replyId: String, ok: Bool, reply: Any?, noListener: Bool) {
        guard let target = pendingReplies.removeValue(forKey: replyId) else { return }
        let js = "window.__desireExt && window.__desireExt._resolveReply(\(Self.quoted(replyId)), \(ok), \(quotedJSON(reply)), \(noListener))"
        target.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 注册 tab → webview 映射（内容脚本插件注入页面时登记，供 tabs.sendMessage 寻址）。
    func registerTabWebview(_ tabID: UUID, webView: WKWebView) {
        tabWebViews.removeAll { $0.tabID == tabID }
        tabWebViews.append(TabWebBox(tabID: tabID, webView: webView))
        if tabWebViews.count > 50 { tabWebViews.removeFirst(tabWebViews.count - 50) }
    }

    private struct TabWebBox { let tabID: UUID; weak var webView: WKWebView? }
    private var tabWebViews: [TabWebBox] = []

    private func replyNoListener(_ replyId: String, to webview: WKWebView) {
        webview.evaluateJavaScript(
            "window.__desireExt && window.__desireExt._resolveReply(\(Self.quoted(replyId)), false, null, true)",
            completionHandler: nil)
    }

    private func quotedJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let str = String(data: data, encoding: .utf8) else { return "null" }
        return str
    }

    func fire(pluginID: UUID, event: String, payload: [String: Any?]) {
        guard let host = hosts[pluginID] else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        host.webView.evaluateJavaScript(
            "window.__desireExt && window.__desireExt._fire(\(Self.quoted(event)), \(json));",
            completionHandler: nil)
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

    // MARK: - RPC 宿主（background webview 的 chrome.* 后端）

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
                        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) {
                            json = str
                        } else {
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
            case ("storage", "get"):
                reply(WebExtensionStore.get(keys: args.first, ext: pluginID.uuidString))
            case ("storage", "set"):
                guard let items = args.first as? [String: Any] else {
                    reply(nil, error: "storage.set requires an object")
                    return
                }
                WebExtensionStore.set(items: items, ext: pluginID.uuidString)
                reply([:])
            case ("storage", "remove"):
                let keys = (args.first as? [Any])?.compactMap { $0 as? String } ?? []
                WebExtensionStore.remove(keys: keys, ext: pluginID.uuidString)
                reply([:])
            case ("storage", "clear"):
                WebExtensionStore.clear(ext: pluginID.uuidString)
                reply([:])
            case ("notifications", "create"):
                WebExtensionStore.createNotification(args.first as? [String: Any] ?? [:]) { result in
                    reply(result)
                }
            case ("contextMenus", "create"):
                guard let props = args.first as? [String: Any],
                      let menuID = (props["id"] as? String) ?? (props["id"] as? NSNumber)?.stringValue else {
                    reply(nil, error: "contextMenus.create requires props.id")
                    return
                }
                let title = props["title"] as? String ?? menuID
                let contexts = (props["contexts"] as? [String]) ?? ["page"]
                PluginContextMenuStore.shared.upsert(
                    pluginID: pluginID, menuID: menuID, title: title, contexts: contexts)
                reply(menuID)
            case ("contextMenus", "remove"):
                if let menuID = args.first as? String {
                    PluginContextMenuStore.shared.remove(pluginID: pluginID, menuID: menuID)
                }
                reply([:])
            case ("contextMenus", "removeAll"):
                PluginContextMenuStore.shared.removeAll(pluginID: pluginID)
                reply([:])
            case ("runtime", "sendMessageToTab"):
                // background/popup → 页面：tabId 寻址投递，回复经 sendReply 回本页。
                guard args.count >= 2,
                      let tabIDString = args[0] as? String,
                      let tabUUID = UUID(uuidString: tabIDString) else {
                    reply(nil, error: "sendMessageToTab requires (tabId, message)")
                    return
                }
                let routedReplyId = "tab-\(id ?? 0)-\(UUID().uuidString)"
                guard let fromWeb = message.webView else {
                    reply(nil, error: "no webview")
                    return
                }
                PluginBackgroundRuntime.shared.deliverToTab(
                    tabID: tabUUID, pluginID: pluginID,
                    message: args[1], sender: ["fromBackground": true],
                    replyId: routedReplyId,
                    fromWebView: fromWeb)
                reply([:])
            case ("runtime", "sendReply"):
                // 页面侧 onMessage 的回复回投（background 发起的 sendMessageToTab）。
                guard args.count >= 2, let envelope = args[1] as? [String: Any] else {
                    reply(nil, error: "sendReply requires (replyId, envelope)")
                    return
                }
                PluginBackgroundRuntime.shared.deliverReply(
                    replyId: args[0] as? String ?? "",
                    ok: (envelope["ok"] as? Bool) == true,
                    reply: envelope["reply"],
                    noListener: (envelope["noListener"] as? Bool) == true)
                reply([:])
            case ("events", "addListener"):
                // background webview 是事件的唯一接收方——无需登记，
                // 宿主派发时直接 evaluate 进来。
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
            case ("tabs", "query"):
                // background 无窗口上下文——查活动窗口的标签快照（与桥同源）。
                let tm = TabSessionCoordinator.shared.activeTabManager
                let tabs: [[String: Any]] = tm?.tabs.enumerated().map { index, t in
                    [
                        "id": t.id.uuidString,
                        "index": index,
                        "url": t.browser.webView.url?.absoluteString ?? t.urlString,
                        "title": t.browser.pageTitle,
                        "active": index == tm?.selectedIndex,
                        "incognito": t.isIncognito,
                        "pinned": t.isPinned,
                    ] as [String: Any]
                } ?? []
                reply(tabs)
            default:
                reply(nil, error: "background runtime: unknown \(ns).\(fn)")
            }
        }
    }
}
