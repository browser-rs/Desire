import Foundation
import WebKit

/// 提及雷达扫描（v0.8.2）：把配置的搜索/社区入口逐个在离屏 webview 里打开，
/// 抽取包含关键词的链接与上下文，去重后写进运营互动台账。
///
/// 只读公开搜索结果；不登录第三方、不绕过访问控制、不自动回复。命中是否
/// 真相关由用户在收件箱/互动台账过目（宁多勿漏，去重与关键词过滤兜底）。
@MainActor
enum MentionRadarScanner {
    struct Result {
        let scannedSources: Int
        let added: Int
        let errors: [String]
        let jobID: UUID?
    }

    static func scan(query: String, sources: [MentionSource],
                     maxHitsPerSource: Int = 15) async -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(scannedSources: 0, added: 0, errors: [], jobID: nil)
        }
        let enabled = sources.filter(\.isEnabled).prefix(6)
        guard !enabled.isEmpty else {
            return Result(scannedSources: 0, added: 0, errors: [], jobID: nil)
        }
        let jobID = JobStore.shared.start(
            title: "Mention scan: \(trimmed)",
            kind: .mentionScan,
            detail: "\(enabled.count) source(s)",
            source: "operations")
        var added = 0
        var scanned = 0
        var errors: [String] = []
        for source in enabled {
            guard let urlString = MentionRadar.searchURL(for: source, query: trimmed),
                  let url = URL(string: urlString) else {
                errors.append("\(source.name): invalid search URL")
                continue
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.customUserAgent = BrowserState._desktopSafariUA
            webView.load(URLRequest(url: url))
            guard await waitReady(webView) else {
                errors.append("\(source.name): page did not finish loading")
                continue
            }
            scanned += 1
            let script = extractionScript(query: trimmed, limit: maxHitsPerSource)
            let value = try? await webView.evaluateJavaScript(script)
            let raw = (value as? String) ?? "[]"
            let hits = parseHits(raw)
            let drafts = MentionRadar.drafts(hits: hits, query: trimmed,
                                             limit: maxHitsPerSource)
            let interactions = drafts.map { draft in
                PromotionInteraction(
                    kind: .mention,
                    platform: source.platform,
                    postURL: source.searchURL,
                    author: source.name,
                    text: draft.snippet.isEmpty ? draft.title : draft.snippet,
                    url: draft.url)
            }
            added += PromotionStore.shared.logInteractions(interactions)
        }
        PromotionStore.shared.markMentionScan()
        let receipt = "Scanned \(scanned) source(s), added \(added) new mention(s)."
            + (errors.isEmpty ? "" : " Errors: " + errors.prefix(3).joined(separator: "; "))
        if scanned == 0, !errors.isEmpty {
            JobStore.shared.finish(jobID, state: .failed, error: receipt)
        } else {
            JobStore.shared.finish(jobID, state: .done, receipt: receipt)
        }
        return Result(scannedSources: scanned, added: added, errors: errors, jobID: jobID)
    }

    private static func parseHits(_ raw: String) -> [MentionRadar.Hit] {
        guard let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return MentionRadar.Hit(url: url,
                                    title: row["title"] as? String ?? "",
                                    snippet: row["snippet"] as? String ?? "")
        }
    }

    private static func waitReady(_ webView: WKWebView,
                                  timeout: TimeInterval = 18) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(350))
        while Date() < end {
            let ready = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if !webView.isLoading, ready == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    private static func extractionScript(query: String, limit: Int) -> String {
        """
        (function(){
          var q = \(JSString.literal(query)).toLowerCase();
          var limit = \(max(1, min(limit, 30)));
          var out = [];
          var seen = {};
          var anchors = document.querySelectorAll('a[href]');
          for (var i = 0; i < anchors.length && out.length < limit; i++) {
            var a = anchors[i];
            var href = a.href || '';
            if (!/^https?:/i.test(href)) { continue; }
            if (seen[href]) { continue; }
            var text = (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim();
            if (text.length < 2) { continue; }
            var box = a.closest('article, li, section, div') || a.parentElement;
            var context = ((box && box.innerText) || text).replace(/\\s+/g, ' ').trim();
            var haystack = (text + ' ' + context).toLowerCase();
            if (haystack.indexOf(q) < 0) { continue; }
            seen[href] = true;
            out.push({url: href, title: text.slice(0, 160), snippet: context.slice(0, 420)});
          }
          return JSON.stringify(out);
        })();
        """
    }
}
