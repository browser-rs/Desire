import Foundation
import WebKit

/// 竞品/市场页面检查（v0.8.3）：后台标签打开来源页，优先用适配包的
/// `opsCompetitor` 视图展平成行，否则读取正文文本；与上次快照 diff 后写回。
/// 只读、不登录、不点击；每次检查后关闭标签。
@MainActor
enum PromotionCompetitorChecker {
    struct Result {
        let changed: Bool
        let summary: String
        let usedView: Bool
        let lines: Int
        let url: String
    }

    static func check(source: PromotionCompetitorSource) async -> Result? {
        guard let url = URL(string: source.url), url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        guard let manager = TabSessionCoordinator.shared.activeTabManager else { return nil }
        let before = Set(manager.tabs.map(\.id))
        manager.addTab(url: url.absoluteString,
                       javaScriptEnabled: true,
                       contentBlocker: AppState.live?.contentBlocker,
                       makeActive: false)
        guard let tab = manager.tabs.first(where: { !before.contains($0.id) }) else { return nil }
        defer {
            if let index = manager.tabs.firstIndex(where: { $0.id == tab.id }) {
                manager.closeTab(at: index)
            }
        }
        let webView = tab.browser.webView
        guard await waitReady(webView) else { return nil }

        let adapter = DPPAdapterStore.shared.adapters.first {
            $0.matchesHost(url.host ?? "") && DPPAdapterStore.shared.isEnabled($0)
        }
        let view = adapter?.protocolBody.views["opsCompetitor"]
        let contentMain = adapter?.protocolBody.contentMain
        var snapshot = ""
        var usedView = false
        if let view {
            let raw = (try? await webView.evaluateJavaScript(viewScript(view))) as? String
            let data = (raw ?? "").data(using: .utf8) ?? Data()
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
            if !rows.isEmpty {
                snapshot = rows.joined(separator: "\n")
                usedView = true
            }
        }
        if snapshot.isEmpty {
            let raw = (try? await webView.evaluateJavaScript(textScript(contentMain))) as? String
            snapshot = raw ?? ""
        }
        let normalized = PromotionCompetitorDiff.normalize(snapshot)
        guard !normalized.isEmpty else { return nil }
        let old = source.lastSnapshot.map { PromotionCompetitorDiff.normalize($0) }
        let diff = PromotionCompetitorDiff.diff(old: old, new: normalized)
        PromotionStore.shared.recordCompetitorCheck(
            source.id, snapshot: normalized,
            changed: diff.changed, summary: diff.summary)
        return Result(changed: diff.changed, summary: diff.summary,
                      usedView: usedView,
                      lines: normalized.split(separator: "\n").count,
                      url: source.url)
    }

    private static func waitReady(_ webView: WKWebView,
                                  timeout: TimeInterval = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while Date() < end {
            let ready = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if !webView.isLoading, ready == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func viewScript(_ view: DesireProtocol.ProtocolView) -> String {
        let item = JSString.literal(view.item)
        var entries: [String] = []
        for (key, spec) in view.fields {
            entries.append("\(JSString.literal(key)): \(JSString.literal(spec.expression))")
        }
        return """
        (function(){
          var item = \(item);
          var fields = {\(entries.joined(separator: ","))};
          var items = document.querySelectorAll(item);
          var out = [];
          for (var i = 0; i < items.length && i < 20; i++) {
            var el = items[i];
            var parts = [];
            for (var key in fields) {
              var expr = fields[key] || '';
              var sel = expr, attr = '';
              var at = expr.lastIndexOf('@');
              if (at > 0) { sel = expr.slice(0, at); attr = expr.slice(at + 1); }
              else if (expr.charAt(0) === '@') { sel = ''; attr = expr.slice(1); }
              var value = '';
              try {
                if (!sel) { value = attr ? el.getAttribute(attr) : el.textContent; }
                else {
                  var node = el.querySelector(sel);
                  if (node) { value = attr ? node.getAttribute(attr) : node.textContent; }
                }
              } catch (e) {}
              value = String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
              if (value) parts.push(key + '=' + value);
            }
            if (parts.length) out.push(parts.join(' | '));
          }
          return JSON.stringify(out);
        })()
        """
    }

    private static func textScript(_ contentMain: String?) -> String {
        let selector = contentMain.map(JSString.literal) ?? "null"
        return """
        (function(){
          var sel = \(selector);
          var node = sel ? document.querySelector(sel) : null;
          var text = node ? node.innerText : (document.body ? document.body.innerText : '');
          return String(text || '').slice(0, 20000);
        })()
        """
    }
}
