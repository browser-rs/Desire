import SwiftUI
import WebKit
import os

/// 白板渲染视图：本地 HTML 壳 + vendored 双引擎（Mermaid v11 / ECharts v5，
/// 零 CDN）。数据流单向：Swift 侧把 `WhiteboardSpec` 序列化后推给
/// `window.renderBoard(spec)`；渲染统计经 message 桥回传（E2E 断言用）。
struct WhiteboardWebView: NSViewRepresentable {
    let spec: WhiteboardSpec
    var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)? = nil

    func makeNSView(context: Context) -> WhiteboardWKWebView {
        let webview = WhiteboardWKWebView()
        let config = webview.configuration
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "whiteboardRender")
        webview.coordinator = context.coordinator
        webview.onRenderStatus = onRenderStatus
        if let baseURL = Bundle.main.resourceURL {
            webview.loadHTMLString(Self.pageHTML, baseURL: baseURL)
        } else {
            webview.loadHTMLString(Self.pageHTML, baseURL: nil)
        }
        pollLoaded(webview)
        return webview
    }

    func updateNSView(_ webview: WhiteboardWKWebView, context: Context) {
        webview.onRenderStatus = onRenderStatus
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

    func makeCoordinator() -> Coordinator { Coordinator(onRenderStatus: onRenderStatus) }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?
        init(onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?) {
            self.onRenderStatus = onRenderStatus
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "whiteboardRender",
                  let dict = message.body as? [String: Any] else { return }
            let rendered = dict["rendered"] as? Int ?? 0
            let errors = dict["errors"] as? [String] ?? []
            // 成图统计进统一日志——E2E/排查的硬证据（webview 内渲染无法截图验证）
            Log.agent.info("Whiteboard render: rendered=\(rendered, privacy: .public) errors=[\(errors.joined(separator: ","), privacy: .public)]")
            Task { @MainActor in
                self.onRenderStatus?(rendered, errors)
            }
        }
    }

    /// WKWebView 子类：携带推送状态与回调（updateNSView 每轮布局都会进来，
    /// 状态挂在 view 上避免对 coordinator 做可变竞争）。
    final class WhiteboardWKWebView: WKWebView {
        var lastPushedJSON: String?
        var pendingJSON: String?
        var loaded = false
        var onRenderStatus: ((_ rendered: Int, _ errors: [String]) -> Void)?
        weak var coordinator: Coordinator?

        /// HTML 文档落地后才能推（见 makeNSView 注释）。
        func pushPending() {
            guard loaded, let json = pendingJSON else { return }
            pendingJSON = nil
            evaluateJavaScript("window.__pendingSpec = \(json); (window.renderBoard || function(){})(window.__pendingSpec); 'pushed'", completionHandler: nil)
        }
    }

    // MARK: - 本地 HTML 壳

    static let pageHTML = """
    <!DOCTYPE html>
    <html lang="zh-Hans">
    <head><meta charset="UTF-8"><style>
      * { box-sizing: border-box; }
      body { font-family: -apple-system, "PingFang SC", sans-serif; color: #211b13;
             background: #f6f1e7; margin: 0; padding: 14px; }
      .block { background: #fffdf7; border: 1px solid #d8cfba; border-radius: 8px;
               padding: 10px 14px; margin-bottom: 12px; }
      .block-title { font-size: 12px; font-weight: 600; color: #8a7f6f; margin: 0 0 6px; }
      .note { font-size: 13px; line-height: 1.7; white-space: pre-wrap; }
      .note h1, .note h2, .note h3 { font-size: 14px; margin: 8px 0 4px; }
      .note strong { font-weight: 700; }
      .mermaid-box svg, .chart-box { max-width: 100%; }
      .err { color: #c03a1a; font-size: 12px; }
      .empty { color: #8a7f6f; font-size: 13px; }
    </style></head>
    <body>
    <div id="board"><div class="empty">白板是空的——让智能体画点什么。</div></div>
    <script src="mermaid.min.js"></script>
    <script src="echarts.min.js"></script>
    <script>
    (function () {
      "use strict";
      var charts = [];
      var ready = false;
      var queued = null;

      function miniMarkdown(text) {
        var esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return esc
          .replace(/^### (.*)$/gm, "<h3>$1</h3>")
          .replace(/^## (.*)$/gm, "<h2>$1</h2>")
          .replace(/^# (.*)$/gm, "<h1>$1</h1>")
          .replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>")
          .replace(/`([^`]+)`/g, "<code>$1</code>")
          .replace(/^- (.*)$/gm, "• $1");
      }

      function el(tag, cls, html) {
        var e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html !== undefined) e.innerHTML = html;
        return e;
      }

      async function renderBlock(block, idx) {
        var wrap = el("div", "block");
        if (block.title) wrap.appendChild(el("p", "block-title", block.title));
        var holder = el("div");
        wrap.appendChild(holder);
        var type = block.type;
        if (type === "mermaid") {
          var box = el("div", "mermaid-box");
          holder.appendChild(box);
          try {
            var out = await mermaid.render("mmd-" + idx + "-" + Date.now(), block.content);
            box.innerHTML = out.svg;
          } catch (e) {
            holder.appendChild(el("p", "err", "Mermaid 渲染失败：" + (e && e.message ? e.message : e)));
          }
        } else if (type === "chart") {
          var chartBox = el("div", "chart-box");
          chartBox.style.width = "100%";
          chartBox.style.height = "320px";
          holder.appendChild(chartBox);
          try {
            var option = JSON.parse(block.content);
            var chart = echarts.init(chartBox);
            chart.setOption(option);
            charts.push(chart);
          } catch (e) {
            holder.appendChild(el("p", "err", "图表渲染失败：" + (e && e.message ? e.message : e)));
          }
        } else if (type === "note") {
          holder.appendChild(el("div", "note", miniMarkdown(block.content)));
        } else {
          holder.appendChild(el("p", "err", "未知块类型：" + type));
        }
        return wrap;
      }

      async function renderBoard(spec) {
        var board = document.getElementById("board");
        board.textContent = "";
        charts.forEach(function (c) { try { c.dispose(); } catch (e) {} });
        charts = [];
        var blocks = (spec && spec.blocks) || [];
        if (!blocks.length) {
          board.appendChild(el("div", "empty", "白板是空的——让智能体画点什么。"));
          post(0, []);
          return;
        }
        if (spec.title) {
          var titleBar = el("p", "block-title", spec.title);
          board.appendChild(titleBar);
        }
        var rendered = 0, errors = [];
        for (var i = 0; i < blocks.length; i++) {
          var before = document.querySelectorAll(".err").length;
          var node = await renderBlock(blocks[i], i);
          board.appendChild(node);
          var after = document.querySelectorAll(".err").length;
          if (after > before) errors.push("block " + (i + 1));
          else rendered++;
        }
        post(rendered, errors);
      }

      function post(rendered, errors) {
        try {
          window.webkit.messageHandlers.whiteboardRender.postMessage(
            { rendered: rendered, errors: errors });
        } catch (e) {}
      }

      function boot() {
        if (ready) return;
        if (!(window.mermaid && window.echarts)) return;
        mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "loose" });
        window.renderBoard = function (spec) { queued = spec; run(); };
        ready = true;
        // Swift 侧的推送可能早于脚本就绪（loadHTMLString 完成前 updateNSView
        // 就跑了）——boot 时补拉早到的 __pendingSpec，否则板永远空。
        if (!queued && window.__pendingSpec) queued = window.__pendingSpec;
        if (queued) run();
      }
      var running = false;
      async function run() {
        if (running || !queued) return;
        running = true;
        var spec = queued;
        try { await renderBoard(spec); } catch (e) {}
        running = false;
      }
      // 脚本加载顺序不确定——轮询到双引擎就绪为止
      var bootTimer = setInterval(boot, 50);
      setTimeout(function () { clearInterval(bootTimer); boot(); }, 5000);
      boot();
      window.addEventListener("resize", function () {
        charts.forEach(function (c) { try { c.resize(); } catch (e) {} });
      });
    })();
    </script>
    </body>
    </html>
    """
}
