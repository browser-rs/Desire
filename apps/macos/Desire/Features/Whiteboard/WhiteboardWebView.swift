import SwiftUI
import WebKit
import os

/// 白板渲染视图：本地 HTML 壳 + vendored 双引擎（Mermaid v11 / ECharts v5，
/// 零 CDN）。数据流单向：Swift 侧把 `WhiteboardSpec` 序列化后推给
/// `window.renderBoard(spec)`；渲染统计经 message 桥回传（E2E 断言用）。
struct WhiteboardWebView: NSViewRepresentable {
    let spec: WhiteboardSpec
    var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)? = nil
    /// 面板编辑回传：kind = move | delete | edit（index 为块序号）。
    var onEdit: ((_ kind: String, _ index: Int, _ delta: Int, _ content: String) -> Void)? = nil
    /// 内容总高（pt）：块渲染完与窗口尺寸变化时上报，供聊天内嵌卡自适应高度。
    var onContentHeight: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> WhiteboardWKWebView {
        let webview = WhiteboardWKWebView()
        let config = webview.configuration
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "whiteboardRender")
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "whiteboardEdit")
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "whiteboardLayout")
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "whiteboardLink")
        webview.coordinator = context.coordinator
        webview.onRenderStatus = onRenderStatus
        webview.onEdit = onEdit
        // 导航护栏（见 WhiteboardWKWebView.decidePolicyFor）。
        webview.navigationDelegate = webview
        // v8：React 版前端（webapp/ 构建产物 Resources/WhiteboardApp/）。
        // loadFileURL 让 index.html 的相对资源（../mermaid.min.js、bundle.js）
        // 在读权限范围内正常加载。
        if let resourceURL = Bundle.main.resourceURL {
            let indexHTML = resourceURL.appendingPathComponent("WhiteboardApp/index.html")
            if FileManager.default.fileExists(atPath: indexHTML.path) {
                webview.loadFileURL(indexHTML, allowingReadAccessTo: resourceURL)
                pollLoaded(webview)
                return webview
            }
        }
        // 兜底：产物缺失（异常安装）时退回占位页（不静默白板）。
        webview.loadHTMLString(Self.legacyFallbackHTML, baseURL: Bundle.main.resourceURL)
        pollLoaded(webview)
        return webview
    }

    func updateNSView(_ webview: WhiteboardWKWebView, context: Context) {
        webview.onRenderStatus = onRenderStatus
        webview.onContentHeight = onContentHeight
        // 变了才推（updateNSView 每轮布局都会进来）；未就绪则挂起，等
        // loadHTMLString 完成回调再推。
        let json = (try? JSONEncoder().encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard json != webview.lastPushedJSON else { return }
        webview.lastPushedJSON = json
        webview.pendingJSON = json
        webview.pushPending()
    }

    /// 轮询到 HTML 文档落地再推 spec——此前在 updateNSView 里立即 evaluate，
    /// 落在 about:blank 上，文档替换后 __pendingSpec 丢失（板永远空）。
    private func pollLoaded(_ webview: WhiteboardWKWebView) {
        if !webview.isLoading {
            webview.loaded = true
            webview.pushPending()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak webview] in
                guard let webview, webview.window != nil || !webview.loaded else { return }
                pollLoaded(webview)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRenderStatus: onRenderStatus, onEdit: onEdit, onContentHeight: onContentHeight)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?
        var onEdit: ((_ kind: String, _ index: Int, _ delta: Int, _ content: String) -> Void)?
        var onContentHeight: ((CGFloat) -> Void)?
        init(onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?,
             onEdit: ((_ kind: String, _ index: Int, _ delta: Int, _ content: String) -> Void)?,
             onContentHeight: ((CGFloat) -> Void)?) {
            self.onRenderStatus = onRenderStatus
            self.onEdit = onEdit
            self.onContentHeight = onContentHeight
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            if message.name == "whiteboardRender" {
                let rendered = dict["rendered"] as? Int ?? 0
                let errors = dict["errors"] as? [String] ?? []
                // 成图统计进统一日志——E2E/排查的硬证据（webview 内渲染无法截图验证）
                Log.agent.info("Whiteboard render: rendered=\(rendered, privacy: .public) errors=[\(errors.joined(separator: ","), privacy: .public)]")
                Task { @MainActor in
                    self.onRenderStatus?(rendered, errors)
                }
                return
            }
            if message.name == "whiteboardLayout" {
                let height = dict["height"] as? Double ?? 0
                Task { @MainActor in
                    self.onContentHeight?(CGFloat(height))
                }
                return
            }
            if message.name == "whiteboardLink" {
                let url = dict["url"] as? String ?? ""
                // note 里的链接在浏览器新标签打开（白板 webview 自身不导航）。
                Task { @MainActor in
                    guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
                    TabSessionCoordinator.shared.activeTabManager?.addTab(url: url)
                }
                return
            }
            if message.name == "whiteboardEdit" {
                let kind = dict["kind"] as? String ?? ""
                let index = dict["index"] as? Int ?? -1
                let delta = dict["delta"] as? Int ?? 0
                let content = dict["content"] as? String ?? ""
                Task { @MainActor in
                    self.onEdit?(kind, index, delta, content)
                }
            }
        }
    }

    /// WKWebView 子类：携带推送状态与回调（updateNSView 每轮布局都会进来，
    /// 状态挂在 view 上避免对 coordinator 做可变竞争）。
    final class WhiteboardWKWebView: WKWebView, WKNavigationDelegate {
        var lastPushedJSON: String?
        var pendingJSON: String?
        var loaded = false
        var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?
        var onEdit: ((_ kind: String, _ index: Int, _ delta: Int, _ content: String) -> Void)?
        var onContentHeight: ((CGFloat) -> Void)?
        weak var coordinator: Coordinator?

        /// 导航护栏：loadHTMLString 落地后取消一切导航——note 里的误点、
        /// 表单提交都不再把白板 webview 打跑（渲染层链接走 whiteboardLink
        /// 消息开浏览器新标签，不产生真实导航）。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(loaded ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // window.open 一律不开新窗。
            nil
        }

        /// HTML 文档落地后才能推（见 makeNSView 注释）。
        func pushPending() {
            guard loaded, let json = pendingJSON else { return }
            pendingJSON = nil
            evaluateJavaScript("window.__pendingSpec = \(json); (window.renderBoard || function(){})(window.__pendingSpec); 'pushed'", completionHandler: nil)
        }
    }

    // MARK: - 本地 HTML 壳

    /// 兜底页（React 前端产物缺失时显示；正常安装不会走到）。
    static let legacyFallbackHTML = """
    <!DOCTYPE html><html lang="zh-Hans"><head><meta charset="UTF-8"><style>
      body { font-family: -apple-system, "PingFang SC", sans-serif; background: #f7f8fa;
             color: #6b7280; display: flex; align-items: center; justify-content: center;
             height: 100vh; margin: 0; font-size: 13px; }
    </style></head><body>白板前端资源缺失——请重新安装 Desire。</body></html>
    """
}
