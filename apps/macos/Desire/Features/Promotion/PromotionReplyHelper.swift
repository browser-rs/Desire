import Foundation
import WebKit

/// 回复台执行体（v0.8.3）：打开互动 URL → 优先用 DPP `opsReply` 声明的
/// 选择器填入回复 → **停在发送前**。绝不点提交；用户自己检查并发送后，
/// 在面板点 Mark replied。
///
/// 安全：只读取适配包声明的 fill 选择器，不执行适配包的其他动作；没有适配
/// 时退回复用安全选择器。全程不读凭据、不发网络请求（页面自身加载除外）。
@MainActor
enum PromotionReplyHelper {
    struct Result {
        let ok: Bool
        let message: String
        let tabURL: String
        let filled: Bool
        let selector: String?
        let source: String // "dpp" | "fallback" | "none"
    }

    static func prepare(interaction: PromotionInteraction, text: String) async -> Result {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            return Result(ok: false, message: "Reply text is empty.",
                          tabURL: "", filled: false, selector: nil, source: "none")
        }
        let rawURL = (interaction.url ?? interaction.postURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL), url.scheme == "http" || url.scheme == "https" else {
            return Result(ok: false, message: "No reply URL recorded for this interaction.",
                          tabURL: rawURL, filled: false, selector: nil, source: "none")
        }
        guard let manager = TabSessionCoordinator.shared.activeTabManager else {
            return Result(ok: false, message: "No active browser window.",
                          tabURL: rawURL, filled: false, selector: nil, source: "none")
        }
        manager.addTab(url: url.absoluteString,
                       javaScriptEnabled: true,
                       contentBlocker: AppState.live?.contentBlocker)
        guard let tab = manager.selectedTab else {
            return Result(ok: false, message: "Could not open a reply tab.",
                          tabURL: rawURL, filled: false, selector: nil, source: "none")
        }
        let webView = tab.browser.webView
        guard await waitReady(webView) else {
            return Result(ok: false, message: "Reply page did not finish loading — paste the reply manually.",
                          tabURL: rawURL, filled: false, selector: nil, source: "none")
        }
        // 等 DPP 解析（didFinish 后异步）——最多 3s；没有协议就退回通用选择器。
        for _ in 0..<12 where !tab.browser.pageProtocolChecked {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let dppSelector = PromotionReplyDesk.dppReplySelector(from: tab.browser.effectiveProtocol)
        var selectors: [String] = []
        if let dppSelector { selectors.append(dppSelector) }
        selectors.append(contentsOf: fallbackSelectors)

        let value = try? await webView.evaluateJavaScript(fillScript(text: reply, selectors: selectors))
        let raw = (value as? String) ?? ""
        let data = raw.data(using: .utf8) ?? Data()
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let filled = parsed?["ok"] as? Bool ?? false
        let usedSelector = parsed?["selector"] as? String
        let source = filled ? ((dppSelector != nil && usedSelector == dppSelector) ? "dpp" : "fallback") : "none"
        if filled {
            let detail = source == "dpp"
                ? "Filled the reply using the site's DPP opsReply selector."
                : "Filled the reply using a generic reply box."
            return Result(ok: true,
                          message: "\(detail) Review it and press Send yourself; then Mark replied.",
                          tabURL: rawURL, filled: true, selector: usedSelector, source: source)
        }
        return Result(ok: false,
                      message: "Opened the page but could not find a reply box — the site likely changed. Paste the reply manually.",
                      tabURL: rawURL, filled: false, selector: nil, source: "none")
    }

    private static let fallbackSelectors = [
        "textarea[placeholder*='回复']",
        "textarea[placeholder*='reply' i]",
        "div[contenteditable='true'][data-testid*='reply' i]",
        ".comment-input [contenteditable]",
        ".reply-input",
        "textarea",
        "div[contenteditable='true']",
    ]

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

    private static func fillScript(text: String, selectors: [String]) -> String {
        let textJSON = JSString.literal(text)
        let selectorsJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: selectors),
                  let json = String(data: data, encoding: .utf8) else { return "[]" }
            return json
        }()
        return """
        (function(){
          var text = \(textJSON);
          var sels = \(selectorsJSON);
          function setValue(el) {
            try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
            try { el.focus(); } catch (e) {}
            if (el.isContentEditable) {
              el.textContent = text;
              try {
                el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
              } catch (e) {
                el.dispatchEvent(new Event('input', { bubbles: true }));
              }
            } else {
              var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
              setter.call(el, text);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }
          for (var i = 0; i < sels.length; i++) {
            var el = document.querySelector(sels[i]);
            if (!el) continue;
            var r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) continue;
            try {
              setValue(el);
              return JSON.stringify({ ok: true, selector: sels[i] });
            } catch (e) {}
          }
          return JSON.stringify({ ok: false });
        })()
        """
    }
}
