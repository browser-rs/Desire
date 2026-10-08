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
      .note-link { color: #2b5aa0; text-decoration: underline; cursor: pointer; }
      .image-box img { max-width: 100%; border-radius: 6px; display: block; -webkit-user-drag: none; }
      .block-handle { cursor: grab; margin-right: 3px; user-select: none; }
      .block.dragging { opacity: 0.45; }
      .block.drop-target { outline: 2px dashed #b48b3c; outline-offset: -2px; }
      .note h1, .note h2, .note h3 { font-size: 14px; margin: 8px 0 4px; }
      .note strong { font-weight: 700; }
      .mermaid-box svg, .chart-box { max-width: 100%; }
      /* Mermaid 图精修（v7）：居中 + 底部呼吸空间；节点文字/边已在
         themeVariables 统一成米纸配色。 */
      .mermaid-box { display: flex; justify-content: center; padding: 6px 2px 10px; }
      .mermaid-box svg { max-width: 100%; height: auto; }
      .mermaid-box svg .flowchart-link { stroke-width: 1.6px; }
      .mermaid-box svg .node rect,
      .mermaid-box svg .node polygon,
      .mermaid-box svg .node circle { filter: drop-shadow(0 1px 1.5px rgba(90,74,48,0.14)); }
      .mermaid-box svg .mindmap-node,
      .mermaid-box svg .mindmap-edges path { font-family: -apple-system, "PingFang SC", sans-serif; }
      /* note 内代码块（v7 扩充：``` 围栏渲染） */
      .note pre { background: #f3ead6; border: 1px solid #e3d9c2; border-radius: 6px;
                  padding: 8px 10px; overflow-x: auto; margin: 6px 0; }
      .note pre code { font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; color: #4a3f2e; }
      .note code { font-family: ui-monospace, Menlo, monospace; font-size: 12px;
                   background: #f3ead6; border-radius: 3px; padding: 1px 4px; }
      .err { color: #c03a1a; font-size: 12px; }
      .empty { color: #8a7f6f; font-size: 13px; }
      .block { position: relative; }
      .block-tools { position: absolute; top: 6px; right: 8px; display: none; gap: 2px; }
      .block:hover .block-tools { display: flex; }
      .block-tools button { border: none; background: transparent; cursor: pointer;
        font-size: 11px; color: #8a7f6f; padding: 2px 4px; border-radius: 4px; }
      .block-tools button:hover { background: #eee7d7; color: #211b13; }
      .block-editor { width: 100%; min-height: 110px; font-family: ui-monospace, Menlo, monospace;
        font-size: 12px; border: 1px solid #d8cfba; border-radius: 6px; padding: 6px 8px; }
      .editor-actions { display: flex; gap: 6px; margin-top: 6px; }
      .editor-actions button { font-size: 12px; padding: 3px 10px; }
      table.md-table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
      table.md-table th, table.md-table td { border: 1px solid #d8cfba; padding: 3px 8px; text-align: left; }
      table.md-table th { background: #eee7d7; }
    </style></head>
    <body>
    <div id="board"><div class="empty">白板是空的——让智能体画点什么。</div></div>
    <script src="mermaid.min.js"></script>
    <script src="echarts.min.js"></script>
    <script>
    (function () {
      "use strict";
      // 图表实例按 .block 节点管理（增量渲染复用节点时不 dispose，
      // 节点被丢弃才 dispose）。
      var chartByNode = new Map();
      var ready = false;
      var queued = null;

      function miniMarkdown(text) {
        // ``` 围栏代码块先摘出（v7）：其余行内规则不得进入 pre。
        // 占位符用 form-feed 字符（Swift 字符串层写双反斜杠）——不会与正文冲突。
        var blocks = [];
        var src = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        src = src.replace(/```([a-zA-Z0-9_]*)\\n([\\s\\S]*?)```/g, function (m, lang, code) {
          blocks.push('<pre><code>' + code + '</code></pre>');
          return "\\fBLOCK" + (blocks.length - 1) + "\\f";
        });
        var out = src
          .replace(/^### (.*)$/gm, "<h3>$1</h3>")
          .replace(/^## (.*)$/gm, "<h2>$1</h2>")
          .replace(/^# (.*)$/gm, "<h1>$1</h1>")
          .replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>")
          .replace(/`([^`]+)`/g, "<code>$1</code>")
          .replace(/\\[([^\\]]+)\\]\\((https?:[^)\\s]+)\\)/g, '<a class="note-link" data-href="$2">$1</a>')
          .replace(/^- (.*)$/gm, "• $1");
        return out.replace(/\\fBLOCK(\\d+)\\f/g, function (m, i) { return blocks[+i]; });
      }

      // markdown 表格 → HTML table（| 分隔；第二行分隔线跳过）
      function renderTable(text) {
        var rows = text.trim().split("\\n").filter(function (l) { return l.trim(); });
        var html = '<table class="md-table">';
        rows.forEach(function (row, ri) {
          var cells = row.replace(/^\\||\\$/g, "").split("|").map(function (c) { return c.trim(); });
          if (cells.length && cells.every(function (c) { return /^:?-+:?$/.test(c); })) return;
          html += "<tr>" + cells.map(function (c) {
            return "<" + (ri === 0 ? "th" : "td") + ">" + miniMarkdown(c) + "</" + (ri === 0 ? "th" : "td") + ">";
          }).join("") + "</tr>";
        });
        return html + "</table>";
      }
      function el(tag, cls, html) {
        var e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html !== undefined) e.innerHTML = html;
        return e;
      }

      // 工具条按钮不带 index——点击经 #board 的事件委托读 .block 的
      // dataset.index（节点可被增量渲染复用，捕获式闭包会拿到过期编号）。
      // 潜伏 bug 修复：旧版这里调 post(...)——那是渲染统计函数（发往
      // whiteboardRender 通道），move/delete 自二期起就没真正生效过。
      // image 块不进源码编辑（content 是万字符 base64，textarea 没意义）。
      function blockTools(canEdit) {
        var bar = el("div", "block-tools");
        var grip = document.createElement("span");
        grip.className = "block-handle";
        grip.textContent = "⠿";
        grip.title = "拖动排序";
        bar.appendChild(grip);
        var items = [["\\u2191", "上移", "move-up"],
         ["\\u2193", "下移", "move-down"]];
        if (canEdit) items.push(["\\u270E", "编辑源码", "edit"]);
        items.push(["\\u2715", "删除", "delete"]);
        items.forEach(function (item) {
          var b = document.createElement("button");
          b.textContent = item[0];
          b.title = item[1];
          b.dataset.action = item[2];
          bar.appendChild(b);
        });
        return bar;
      }

      function postEdit(payload) {
        try { window.webkit.messageHandlers.whiteboardEdit.postMessage(payload); } catch (e) {}
      }

      var editing = -1;
      function startEdit(idx) {
        var block = (window.__currentSpec.blocks || [])[idx];
        var row = document.querySelectorAll(".block")[idx];
        if (!block || !row) return;
        editing = idx;
        renderBoard(window.__currentSpec);
      }

      function editorActions(idx) {
        var actions = el("div", "editor-actions");
        var save = document.createElement("button");
        save.textContent = "保存";
        save.onclick = function () {
          var editor = document.querySelectorAll(".block")[idx].querySelector(".block-editor");
          var content = editor ? editor.value : "";
          editing = -1;
          postEdit({ kind: "edit", index: idx, content: content });
        };
        var cancel = document.createElement("button");
        cancel.textContent = "取消";
        cancel.onclick = function () { editing = -1; renderBoard(window.__currentSpec); };
        actions.appendChild(save); actions.appendChild(cancel);
        return actions;
      }

      async function renderBlock(block, idx) {
        var wrap = el("div", "block");
        wrap.dataset.index = idx;
        var editingThis = editing === idx;
        if (!editingThis && block.title) wrap.appendChild(el("p", "block-title", block.title));
        if (!editingThis) wrap.appendChild(blockTools(block.type !== "image"));
        var holder = el("div");
        wrap.appendChild(holder);
        if (editingThis) {
          var editor = el("textarea", "block-editor");
          editor.value = block.content;
          holder.appendChild(editor);
          wrap.appendChild(editorActions(idx));
          return wrap;
        }
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
          var chartH = (typeof block.height === "number" && isFinite(block.height)) ? Math.min(Math.max(block.height, 120), 800) : 320;
          chartBox.style.height = Math.round(chartH) + "px";
          holder.appendChild(chartBox);
          try {
            var option = JSON.parse(block.content);
            var chart = echarts.init(chartBox);
            chart.setOption(option);
            chartByNode.set(wrap, chart);
          } catch (e) {
            holder.appendChild(el("p", "err", "图表渲染失败：" + (e && e.message ? e.message : e)));
          }
        } else if (type === "note") {
          holder.appendChild(el("div", "note", miniMarkdown(block.content)));
        } else if (type === "table") {
          holder.innerHTML = renderTable(block.content);
        } else if (type === "image") {
          if (!/^data:image\\//.test(block.content)) {
            holder.appendChild(el("p", "err", "Image block must be a data:image/ URI"));
          } else {
            var imageBox = el("div", "image-box");
            var img = document.createElement("img");
            img.src = block.content;
            img.alt = block.title || "image";
            imageBox.appendChild(img);
            holder.appendChild(imageBox);
          }
        } else {
          holder.appendChild(el("p", "err", "未知块类型：" + type));
        }
        return wrap;
      }

      // 上一次渲染的块（type/title/content + DOM 节点）：增量渲染用——
      // 内容未变的块直接复用节点，ECharts 实例保留不重建，append/单块
      // 编辑不再整板闪烁重渲。
      var lastBlocks = [];
      var lastNodes = [];

      function disposeNode(node) {
        var ch = chartByNode.get(node);
        if (ch) { try { ch.dispose(); } catch (e) {} chartByNode.delete(node); }
      }

      function sameBlock(a, b) {
        return a.type === b.type && a.title === b.title && a.content === b.content;
      }

      async function renderBoard(spec) {
        window.__currentSpec = spec;
        var keepEditing = editing;
        editing = -1;
        var board = document.getElementById("board");
        var blocks = (spec && spec.blocks) || [];
        var used = lastNodes.map(function () { return false; });
        board.textContent = "";
        if (!blocks.length) {
          lastNodes.forEach(disposeNode);
          lastBlocks = [];
          lastNodes = [];
          board.appendChild(el("div", "empty", "白板是空的——让智能体画点什么。"));
          post(0, []);
          postHeight();
          return;
        }
        if (spec.title) {
          board.appendChild(el("p", "block-title", spec.title));
        }
        var rendered = 0, errors = [];
        var newNodes = [];
        var newMeta = [];
        for (var i = 0; i < blocks.length; i++) {
          if (keepEditing === i) editing = i;
          var node = null;
          if (keepEditing !== i) {
            for (var j = 0; j < lastBlocks.length; j++) {
              if (used[j]) continue;
              // 编辑态节点（textarea）永不复用；带错误的节点不复用
              //（同内容重试要真渲染）。
              if (lastNodes[j].querySelector(".block-editor") ||
                  lastNodes[j].querySelector(".err")) continue;
              if (sameBlock(lastBlocks[j], blocks[i])) {
                node = lastNodes[j];
                used[j] = true;
                break;
              }
            }
          }
          if (node) {
            node.dataset.index = i;
            board.appendChild(node);
            var chart = chartByNode.get(node);
            if (chart) { try { chart.resize(); } catch (e) {} }
            rendered++;
          } else {
            node = await renderBlock(blocks[i], i);
            board.appendChild(node);
            if (node.querySelectorAll(".err").length > 0) errors.push("block " + (i + 1));
            else rendered++;
          }
          newNodes.push(node);
          newMeta.push({ type: blocks[i].type, title: blocks[i].title, content: blocks[i].content });
        }
        for (var j = 0; j < lastNodes.length; j++) {
          if (!used[j]) disposeNode(lastNodes[j]);
        }
        lastBlocks = newMeta;
        lastNodes = newNodes;
        post(rendered, errors);
        postHeight();
      }

      function post(rendered, errors) {
        // 离屏成图服务（BoardRenderService）以 at 时间戳门控等这次渲染
        window.__lastRenderStats = { rendered: rendered, errors: errors, at: Date.now() };
        try {
          window.webkit.messageHandlers.whiteboardRender.postMessage(
            { rendered: rendered, errors: errors });
        } catch (e) {}
      }

      // 内容总高：body 高度自动包裹内容（与视口无关，不会因 frame 变高而
      // 只增不减），供内嵌卡把 frame 收敛到内容实际高度。
      function postHeight() {
        try {
          window.webkit.messageHandlers.whiteboardLayout.postMessage(
            { height: Math.ceil(document.body.scrollHeight) + 2 });
        } catch (e) {}
      }

      // 块工具条事件委托：编号以 .block 的 dataset.index 为准（增量渲染
      // 复用节点后，闭包捕获的编号会过期）。
      document.getElementById("board").addEventListener("click", function (ev) {
        var btn = ev.target && ev.target.closest ? ev.target.closest(".block-tools button") : null;
        if (!btn) return;
        var blockEl = btn.closest(".block");
        var idx = blockEl ? parseInt(blockEl.dataset.index, 10) : NaN;
        if (isNaN(idx)) return;
        var act = btn.dataset.action;
        if (act === "move-up") postEdit({ kind: "move", index: idx, delta: -1 });
        else if (act === "move-down") postEdit({ kind: "move", index: idx, delta: 1 });
        else if (act === "edit") startEdit(idx);
        else if (act === "delete") postEdit({ kind: "delete", index: idx });
      });

      // 拖拽排序：手柄 mousedown 才把块置 draggable（不破坏 note 文本
      // 选择），drop 目标块的 dataset.index 即新位置，经 reorder 回传。
      var dragFrom = -1;
      document.getElementById("board").addEventListener("mousedown", function (ev) {
        var grip = ev.target && ev.target.closest ? ev.target.closest(".block-handle") : null;
        if (!grip) return;
        var blockEl = grip.closest(".block");
        if (blockEl) blockEl.draggable = true;
      });
      document.getElementById("board").addEventListener("dragstart", function (ev) {
        var blockEl = ev.target && ev.target.closest ? ev.target.closest(".block") : null;
        if (!blockEl || !blockEl.draggable) { ev.preventDefault(); return; }
        dragFrom = parseInt(blockEl.dataset.index, 10);
        if (isNaN(dragFrom)) { ev.preventDefault(); return; }
        ev.dataTransfer.effectAllowed = "move";
        blockEl.classList.add("dragging");
      });
      document.getElementById("board").addEventListener("dragover", function (ev) {
        ev.preventDefault();
        var blockEl = ev.target && ev.target.closest ? ev.target.closest(".block") : null;
        var marked = document.querySelectorAll(".block.drop-target");
        for (var i = 0; i < marked.length; i++) marked[i].classList.remove("drop-target");
        if (blockEl) blockEl.classList.add("drop-target");
      });
      document.getElementById("board").addEventListener("drop", function (ev) {
        ev.preventDefault();
        var blockEl = ev.target && ev.target.closest ? ev.target.closest(".block") : null;
        var to = blockEl ? parseInt(blockEl.dataset.index, 10) : NaN;
        if (!isNaN(dragFrom) && !isNaN(to) && to !== dragFrom) {
          postEdit({ kind: "reorder", index: dragFrom, delta: to });
        }
        dragFrom = -1;
      });
      document.getElementById("board").addEventListener("dragend", function () {
        dragFrom = -1;
        var marked = document.querySelectorAll(".block.dragging, .block.drop-target");
        for (var i = 0; i < marked.length; i++) marked[i].classList.remove("dragging", "drop-target");
      });

      // note 链接点击 → 经桥在浏览器新标签打开（真实导航被 Swift 侧护栏
      // 取消，白板 webview 永远不离开自己的文档）。
      document.addEventListener("click", function (ev) {
        var t = ev.target;
        var a = t && t.closest ? t.closest(".note-link") : null;
        if (!a) return;
        ev.preventDefault();
        var url = a.getAttribute("data-href");
        if (url) {
          try { window.webkit.messageHandlers.whiteboardLink.postMessage({ url: url }); } catch (e) {}
        }
      });

      function boot() {
        if (ready) return;
        if (!(window.mermaid && window.echarts)) return;
        // v7 美化：theme base + 米纸主题变量（墨字 #211b13 / 朱金 #b48b3c /
        // 灰褐线 #8a7f6f），连线平滑曲线（basis）替代原始直角折线，
        // flowchart 节点圆角 + 内边距。此前 theme neutral = 生成的流程图
        // 灰白直角线，观感"原始"。
        mermaid.initialize({
          startOnLoad: false,
          theme: "base",
          securityLevel: "loose",
          themeVariables: {
            fontFamily: '-apple-system, "PingFang SC", sans-serif',
            // fontSize 必须是**数字**：mermaid 主题计算会拿它做乘法
            //（fontSize*spacing），字符串 "14px" 让整条主题链变 NaN
            // 静默回退默认灰主题（实测 themeVariables 全部失效的真因）。
            fontSize: 14,
            primaryColor: "#fbf3e2",
            primaryTextColor: "#211b13",
            primaryBorderColor: "#b48b3c",
            secondaryColor: "#f3e7cd",
            tertiaryColor: "#f6f1e7",
            lineColor: "#8a7f6f",
            textColor: "#211b13",
            mainBkg: "#fbf3e2",
            nodeBorder: "#b48b3c",
            clusterBkg: "#f3ead6",
            clusterBorder: "#d8cfba",
            edgeLabelBackground: "#fffdf7",
            noteBkgColor: "#fdf6e2",
            noteBorderColor: "#d8cfba"
          },
          flowchart: { curve: "basis", padding: 10, nodeSpacing: 42, rankSpacing: 52 },
          sequence: { actorFontFamily: '-apple-system', noteFontFamily: '-apple-system' },
          // mindmap 节点的下划线默认深蓝（#0000cc 系），与米纸主题不搭——
          // themeCSS 精确覆盖（类名以 v11 DOM 为准：.mindmap-node 内 path）。
          themeCSS: ".mindmap-node path, .mindmap-node rect, .mindmap-node line { stroke: #a8865a !important; stroke-width: 1.6px !important; }"
        });
        window.renderBoard = function (spec) { queued = spec; run(); };
        window.__editing = function () { return editing; };
        window.__startEdit = function (idx) { startEdit(idx); };
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
      var heightTimer = null;
      window.addEventListener("resize", function () {
        chartByNode.forEach(function (c) { try { c.resize(); } catch (e) {} });
        if (heightTimer) clearTimeout(heightTimer);
        heightTimer = setTimeout(postHeight, 150);
      });
    })();
    </script>
    </body>
    </html>
    """
}
