import Foundation
import os
import WebKit

/// DevTools 记录器（0.7.5）：console/network 的**接收端**与 SwiftUI 视图
/// 生命周期解耦。此前 Coordinator.observe() 在 makeNSView 挂 handler、
/// dismantle 摘——标签页一转后台记录就断，"全部标签页"只剩被前台化过的
/// 那些名单。现改为 app 级单例：Tab 创建时装上（归属从 webview 的
/// `devToolsTabID` 读），挂起重建（BrowserState.rebuildWebView）随新
/// webview 重装。发送侧（console-intercept.js / network-monitor.js）本就是
/// 建 webview 时的常驻 user script，全程不动。
///
/// 注意：`devConsole`/`netEntry` 两个 handler 名自此处独占——
/// Coordinator.observe() 的 remove-before-add 台账（scriptMessageHandlers）
/// 不得再包含这两个名字，否则每次视图重建都会把本记录器摘掉。
@MainActor
final class DevToolsRecorder: NSObject, WKScriptMessageHandler {
    static let shared = DevToolsRecorder()

    func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        // remove-before-add：Tab 重建/重复安装幂等。
        controller.removeScriptMessageHandler(forName: "devConsole")
        controller.removeScriptMessageHandler(forName: "netEntry")
        controller.add(self, name: "devConsole")
        controller.add(self, name: "netEntry")
        Log.userScripts.info("devtools recorder installed on \(webView.url?.host ?? "nil", privacy: .public)")
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        handle(message)
    }

    private func handle(_ message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        guard let tabID = (message.webView as? BrowserWKWebView)?.devToolsTabID else { return }
        guard let store = AppState.live?.devToolsStore else { return }
        // 消息路径顺手登记标签页（与旧 Coordinator 同款兜底：后台标签页
        // 的导航代理被挂起路径置空，didStart/didFinish 不会触发）。
        store.noteTab(id: tabID,
                      title: message.webView?.title,
                      url: message.webView?.url?.absoluteString)
        switch message.name {
        case "devConsole":
            guard let levelStr = dict["level"] as? String,
                  let msgText = dict["message"] as? String else { return }
            store.addConsoleMessage(
                level: ConsoleMessage.Level(rawValue: levelStr) ?? .log,
                message: msgText,
                url: dict["url"] as? String,
                line: dict["line"] as? Int,
                column: dict["column"] as? Int,
                tabID: tabID,
                parts: ConsoleMessage.parseParts(dict["parts"]))
        case "netEntry":
            store.applyNetworkEvent(dict, tabID: tabID)
            // webRequest.onBeforeRequest（MV3 观察语义）：请求 start 一发。
            if (dict["phase"] as? String) == "start" {
                var details: [String: Any] = [
                    "url": dict["url"] as? String ?? "",
                    "tabId": tabID.uuidString,
                    "frameId": 0,
                ]
                if let resourceType = dict["resourceType"] as? String {
                    details["type"] = resourceType
                }
                if let method = dict["method"] as? String {
                    details["method"] = method
                }
                PluginBackgroundRuntime.shared.fireWebRequest(details: details)
            }
        default:
            break
        }
    }
}
