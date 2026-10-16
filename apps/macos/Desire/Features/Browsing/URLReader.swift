import Foundation
import WebKit

/// 离屏取正文（v0.7.18）：**不开标签**读一个链接说了什么——"读一下这篇
/// 给我要点"、"把这几个链接都看看"，以及热点选题/批量阅读的地基。
///
/// 两条路与阅读列表缓存同款：目标页面**已经打开**就直接借它的 webview 读
/// （零等待、含登录态，也不打扰页面）；没打开才离屏加载（一次性 webview +
/// **当前档案的 data store**，带与主浏览一致的桌面 Safari UA；轮询
/// isLoading，20s 超时后退场）。正文取 `body.innerText`（尊重 CSS 可见性），
/// 压缩连续空行后封顶截断；shadow DOM/跨源 iframe 的正文不在内（如实标注）。
@MainActor
enum URLReader {
    struct Result {
        let title: String
        let text: String
        let finalURL: String
        let links: [(text: String, href: String)]
        let fromOpenTab: Bool
        let truncated: Bool
    }

    /// 读 `url` 的正文；链接清单可选。失败（URL 非法/加载超时/取文失败）返回 nil。
    static func read(url rawURL: String, maxChars: Int = 20_000, includeLinks: Bool = true) async -> Result? {
        guard let target = normalize(rawURL) else { return nil }

        let webview: WKWebView
        let fromOpenTab: Bool
        if let openView = ReadingListCache.openTabWebview(matching: target.absoluteString) {
            webview = openView
            fromOpenTab = true
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = ProfileStore.shared.dataStore(
                for: TabSessionCoordinator.shared.activeTabManager?.profileID)
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
            let offscreen = WKWebView(frame: .zero, configuration: configuration)
            BrowserState.applyDesktopSafariUA(to: offscreen)
            offscreenReaderWebview = offscreen
            webview = offscreen
            fromOpenTab = false
            webview.load(URLRequest(url: target))
            var finished = false
            for _ in 0..<200 {   // ≤20s
                if !webview.isLoading { finished = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard finished else {
                offscreenReaderWebview = nil
                return nil
            }
            // 让晚到的 JS 渲染落定（与阅读列表缓存同一手法）。
            try? await Task.sleep(for: .milliseconds(500))
        }

        let script = Self.extractionScript(includeLinks: includeLinks)
        let raw = await withCheckedContinuation { continuation in
            webview.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        offscreenReaderWebview = nil
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let title = (object["title"] as? String) ?? ""
        var text = (object["text"] as? String) ?? ""
        let finalURL = (object["url"] as? String) ?? target.absoluteString
        var truncated = false
        if text.count > maxChars {
            text = String(text.prefix(maxChars))
            truncated = true
        }
        var links: [(text: String, href: String)] = []
        if includeLinks, let rawLinks = object["links"] as? [[String: String]] {
            links = rawLinks.compactMap { item in
                guard let t = item["text"], !t.isEmpty, let href = item["href"] else { return nil }
                return (text: t, href: href)
            }
        }
        return Result(title: title, text: text, finalURL: finalURL,
                      links: links, fromOpenTab: fromOpenTab, truncated: truncated)
    }

    /// 离屏读文 webview（一次一个；完成即释放，别常驻）。
    private static var offscreenReaderWebview: WKWebView?

    /// 纯逻辑：URL 归一——补 scheme（默认 https，localhost/IP 走 http）、
    /// 只收 http(s)。非法（空格/无主机）返回 nil。
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        var candidate = trimmed
        if !candidate.contains("://") {
            let host = candidate.split(separator: "/").first.map(String.init) ?? ""
            let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("[::1]")
            candidate = (isLocal ? "http://" : "https://") + candidate
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 页面取文脚本：innerText（尊重 CSS 可见性）+ 压缩空行 + 可选链接清单。
    private static func extractionScript(includeLinks: Bool) -> String {
        let linksClause = includeLinks
            ? """
              var links = Array.prototype.slice.call(document.querySelectorAll('a[href]')).slice(0, 60)
                .map(function (a) { return { text: (a.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 80), href: a.href }; })
                .filter(function (l) { return l.text && /^https?:/.test(l.href); });
              """
            : "var links = [];"
        return """
        (function () {
          var body = document.body;
          var text = body ? (body.innerText || '') : '';
          text = text.replace(/\\u00a0/g, ' ').replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
          \(linksClause)
          return JSON.stringify({ title: document.title || '', text: text, url: location.href, links: links });
        })()
        """
    }
}
