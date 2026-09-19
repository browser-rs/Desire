import Combine
import SwiftUI
import WebKit
@preconcurrency import UserNotifications

/// 扩展 popup 宿主（0.3.3）：固定图标的插件若带 popup 页（manifest
/// action.default_popup），点击弹出本视图——一个独立小 WKWebView，
/// 隔离 `desireExtensions` 世界注入 webext-api 运行时 + 插件身份，
/// popup 的 HTML 是插件自带的。
///
/// v1 RPC 面：storage.local / notifications / runtime（popup 常用集）。
/// tabs.* 在 popup 语境意义有限，v2 再补。
struct ExtensionPopupWebView: NSViewRepresentable {
    let plugin: Plugin
    /// 弹窗建议尺寸（manifest 无尺寸字段；Chrome 默认 800×600 太大，
    /// Desire 取紧凑 320×420，popup 页自适应滚动）。
    var size: CGSize = CGSize(width: 320, height: 420)

    func makeCoordinator() -> Coordinator { Coordinator(pluginID: plugin.id.uuidString) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let content = config.userContentController
        content.removeScriptMessageHandler(forName: "desireExt", contentWorld: WebView.extensionWorld)
        content.add(context.coordinator, contentWorld: WebView.extensionWorld, name: "desireExt")
        let runtime = UserScriptLoader.load("webext-api")
        if !runtime.isEmpty {
            content.addUserScript(WKUserScript(
                source: runtime + "\nwindow.__desireExtID = '\(plugin.id.uuidString)';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: WebView.extensionWorld))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString(plugin.popupHTML ?? "", baseURL: nil)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let pluginID: String
        init(pluginID: String) { self.pluginID = pluginID }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
                } else if let payload,
                          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                          let str = String(data: data, encoding: .utf8) {
                    json = str
                } else {
                    json = "null"
                }
                message.webView?.evaluateJavaScript(
                    "window.__desireExt && window.__desireExt._resolve(\(id), \(error == nil), \(json))",
                    in: nil, in: WebView.extensionWorld, completionHandler: nil)
            }

            switch (ns, fn) {
            case ("storage", "get"):
                reply(WebExtensionStore.get(keys: args.first, ext: pluginID))
            case ("storage", "set"):
                guard let items = args.first as? [String: Any] else {
                    reply(nil, error: "storage.set requires an object")
                    return
                }
                WebExtensionStore.set(items: items, ext: pluginID)
                reply([:])
            case ("storage", "remove"):
                let keys = (args.first as? [Any])?.compactMap { $0 as? String } ?? []
                WebExtensionStore.remove(keys: keys, ext: pluginID)
                reply([:])
            case ("storage", "clear"):
                WebExtensionStore.clear(ext: pluginID)
                reply([:])
            case ("notifications", "create"):
                WebExtensionStore.createNotification(args.first as? [String: Any] ?? [:]) { result in
                    reply(result)
                }
            default:
                reply(nil, error: "popup v1 supports storage/notifications only (got \(ns).\(fn))")
            }
        }
    }
}
