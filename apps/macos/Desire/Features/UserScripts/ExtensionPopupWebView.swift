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
        // ⚠️ 运行时必须注入**页面世界**（.page）——popup 的内联 <script>
        // （装载时已把 popup.js 内联进 HTML）跑在页面世界，若把 chrome.*
        // 注入隔离 world，popup 里 chrome 是 undefined，首个 API 调用即抛，
        // 三个视图（初始全 hidden）永远不展开 = 空白弹窗（实测踩过）。
        // 本 webview 只加载插件自带的 popup HTML，页面世界注入是安全的，
        // 且与 Chrome 语义一致（popup 脚本直接可见 chrome.*）。
        content.removeScriptMessageHandler(forName: "desireExt", contentWorld: .page)
        content.add(context.coordinator, contentWorld: .page, name: "desireExt")
        let runtime = UserScriptLoader.load("webext-api")
        if !runtime.isEmpty {
            content.addUserScript(WKUserScript(
                source: PluginI18N.prologue(resourcesPath: plugin.resourcesPath)
                    + runtime + "\nwindow.__desireExtID = '\(plugin.id.uuidString)';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        // baseURL = manifest host_permissions 的 origin：文档 origin 变成 API
        // 同源，popup 里的 fetch 不再被 CORS 拦（见 Plugin.popupBaseOrigin 注释）。
        let base = plugin.popupBaseOrigin.flatMap(URL.init(string:))
        web.loadHTMLString(plugin.popupHTML ?? "", baseURL: base)
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
                } else if let payload {
                    // 标量顶层手动字符串化（JSONSerialization 默认拒绝标量，
                    // 抛的是 ObjC 异常 try? 拦不住——背景 Coordinator 同款修法，
                    // contextMenus.create 回菜单 id 即触发）；非 JSON 容器
                    // （DOM 节点等 Objective-C 对象）先过 isValid 再序列化。
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

            // 宿主 RPC 收口（2026-10-02 审查）：popup 与背景页共用同一份
            // 实现（此前 popup 只有 storage/notifications/tabs.query 五个
            // case，扩展主 UI 调 tabs/runtime/i18n 全挂）。
            let popupUUID = UUID(uuidString: pluginID) ?? UUID()
            let popupReply = reply
            Task { @MainActor in
                await PluginBackgroundRuntime.dispatchHostRPC(
                    ns: ns, fn: fn, args: args, pluginID: popupUUID,
                    sourceWebView: message.webView) { payload, error in
                    popupReply(payload, error)
                }
            }
        }
    }
}
