import AppKit
import Foundation
import WebKit

/// 研究简报的页面抓取（v0.8.50 批 2）：**非持久会话**（不共享用户 cookie，
/// 登录墙站点因此抓不到正文、标 gated/empty），加载完成后用阅读模式同款
/// 启发式取主正文。
///
/// 纪律：单页 20s 超时；并发与域名间隔由 `ResearchBriefService` 控制；
/// 抓取结束立刻拆掉 webview（不占内存、不进用户标签）。
@MainActor
final class ResearchBriefPageFetcher {
    struct Result {
        var title: String
        var text: String
        var finalURL: String
        var publishedAt: String?
        /// 失败/受限归因：empty / login / timeout / http。
        var note: String?
    }

    static let shared = ResearchBriefPageFetcher()

    /// 每页最多回传的字符数（进模型前 composer 还会再截）。
    private static let maxTextChars = 120_000

    func fetch(url: URL, timeout: TimeInterval = 20) async -> Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Result(title: "", text: "", finalURL: url.absoluteString, publishedAt: nil, note: "http")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"
        config.setValue(false, forKey: "systemTextExtractionEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter

        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: timeout))
        let timeoutTask = Task { @MainActor [waiter] in
            try? await Task.sleep(for: .seconds(timeout))
            waiter.finish(false, timeout: true)
        }
        let loaded = await waiter.wait()
        timeoutTask.cancel()

        guard loaded else {
            webView.stopLoading()
            webView.navigationDelegate = nil
            let timedOut = waiter.timedOut
            return Result(title: "", text: "", finalURL: url.absoluteString,
                          publishedAt: nil, note: timedOut ? "timeout" : "http")
        }

        // 给 SPA/懒加载一点时间把正文渲染出来（不无限等）。
        try? await Task.sleep(for: .milliseconds(800))
        let script = """
        (function(){
          function text(el){ return (el && (el.innerText || el.textContent) || '').replace(/\\s+/g,' ').trim(); }
          var nodes = document.querySelectorAll('article, main, [role=main], #content, .post-content, .article-body, .entry-content');
          var best = '';
          for (var i = 0; i < nodes.length; i++) {
            var t = text(nodes[i]);
            if (t.length > best.length) best = t;
          }
          var body = best.length > 200 ? best : text(document.body);
          var meta = document.querySelector('meta[property="article:published_time"], meta[name="date"], meta[property="og:updated_time"]');
          return JSON.stringify({
            title: document.title || '',
            text: body.slice(0, \(Self.maxTextChars)),
            published: meta ? (meta.getAttribute('content') || '') : '',
            url: location.href
          });
        })()
        """
        let raw = (try? await webView.evaluateJavaScript(script)) as? String ?? ""
        webView.stopLoading()
        webView.navigationDelegate = nil

        var result = Result(title: "", text: "", finalURL: webView.url?.absoluteString ?? url.absoluteString,
                            publishedAt: nil, note: nil)
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.title = object["title"] as? String ?? ""
            result.text = object["text"] as? String ?? ""
            let published = object["published"] as? String ?? ""
            if !published.isEmpty { result.publishedAt = published }
            if let final = object["url"] as? String, !final.isEmpty { result.finalURL = final }
        }
        let lowerFinal = result.finalURL.lowercased()
        if result.text.count < 200 {
            result.note = lowerFinal.contains("login") || lowerFinal.contains("signin")
                ? "login" : "empty"
        }
        return result
    }
}

/// 单次导航的一次性等待器（超时/成功/失败三条路径只放行一次）。
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    private var outcome = false
    private(set) var timedOut = false

    func wait() async -> Bool {
        if finished { return outcome }
        return await withCheckedContinuation { cont in
            if finished {
                cont.resume(returning: outcome)
            } else {
                continuation = cont
            }
        }
    }

    func finish(_ ok: Bool, timeout: Bool = false) {
        guard !finished else { return }
        finished = true
        outcome = ok
        if timeout { timedOut = true }
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(false)
    }
}
