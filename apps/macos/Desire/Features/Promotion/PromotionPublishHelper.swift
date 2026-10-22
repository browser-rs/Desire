import Foundation
import WebKit

/// 运营发布准备（v0.8.2）：打开渠道 composer，把草稿标题/正文填进去，然后
/// **停在发布前**——最终发布按钮永远由用户按（红线：任何公开发布/回复都必须
/// 人工批准）。发布完成后再用 `PromotionStore.markPublished` 记 URL。
///
/// 选择器是各平台常见结构的尽力而为版本；平台改版时给出"没找到输入框"的
/// 明确结果，而不是假装填好了。
@MainActor
enum PromotionPublishHelper {
    struct Result {
        let ok: Bool
        let message: String
        let tabURL: String
        let filledTitle: Bool
        let filledBody: Bool
        let jobID: UUID?
    }

    static func prepare(post: PromotionPost,
                        composerURLOverride: String? = nil) async -> Result {
        let channel = PromotionChannel.preset(platform: post.platform)
        let composer = composerURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (composer?.isEmpty == false ? composer : nil)
            ?? channel?.composerURL
        guard let target, let url = URL(string: target) else {
            return Result(ok: false,
                          message: "No composer URL for \(post.platform). Add one in the channel profile or open the site manually.",
                          tabURL: "", filledTitle: false, filledBody: false, jobID: nil)
        }
        guard let manager = TabSessionCoordinator.shared.activeTabManager else {
            return Result(ok: false, message: "No active browser window.",
                          tabURL: "", filledTitle: false, filledBody: false, jobID: nil)
        }
        let jobID = JobStore.shared.start(
            title: "Prepare publish: \(post.title)",
            kind: .publish,
            detail: "\(post.platform) · \(post.title)",
            source: "operations",
            externalID: post.id.uuidString)
        manager.addTab(url: url.absoluteString,
                       javaScriptEnabled: true,
                       contentBlocker: AppState.live?.contentBlocker)
        guard let tab = manager.selectedTab else {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: "Could not open a composer tab.")
            return Result(ok: false, message: "Could not open a composer tab.",
                          tabURL: url.absoluteString, filledTitle: false, filledBody: false,
                          jobID: jobID)
        }
        let webView = tab.browser.webView
        guard await waitReady(webView) else {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: "Composer page did not finish loading.")
            return Result(ok: false, message: "Composer page did not finish loading.",
                          tabURL: url.absoluteString, filledTitle: false, filledBody: false,
                          jobID: jobID)
        }
        let script = fillScript(title: post.title, body: post.body,
                                voice: channel?.voice ?? .technical)
        let value = try? await webView.evaluateJavaScript(script)
        let raw = (value as? String) ?? ""
        let data = raw.data(using: .utf8) ?? Data()
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let filledTitle = parsed?["title"] as? Bool ?? false
        let filledBody = parsed?["body"] as? Bool ?? false
        if filledTitle || filledBody {
            let parts = [filledTitle ? "title" : nil, filledBody ? "body" : nil]
                .compactMap { $0 }.joined(separator: " + ")
            let message = "Filled \(parts) in the composer. Review it and press Publish yourself; then use Mark Published to record the URL."
            JobStore.shared.finish(jobID, state: .needsReview,
                                   receipt: message, artifactURL: url.absoluteString)
            return Result(ok: true, message: message,
                          tabURL: url.absoluteString,
                          filledTitle: filledTitle, filledBody: filledBody,
                          jobID: jobID)
        }
        let message = "Composer opened, but no title/body field was found — the site likely changed. Copy the draft and paste it manually."
        JobStore.shared.finish(jobID, state: .failed,
                               artifactURL: url.absoluteString, error: message)
        return Result(ok: false, message: message,
                      tabURL: url.absoluteString, filledTitle: false, filledBody: false,
                      jobID: jobID)
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

    private static func fillScript(title: String, body: String,
                                   voice: PromotionChannel.Voice) -> String {
        let titleSelectors: [String]
        let bodySelectors: [String]
        switch voice {
        case .x, .microblog:
            titleSelectors = []
            bodySelectors = [
                "div[contenteditable=\"true\"][data-testid=\"tweetTextarea_0\"]",
                "div[contenteditable=\"true\"]",
                "textarea",
            ]
        case .xiaohongshu:
            titleSelectors = [
                "input[placeholder*=\"标题\"]",
                "input[placeholder*=\"title\" i]",
                "input[name=\"title\"]",
            ]
            bodySelectors = [
                "div[contenteditable=\"true\"]",
                "textarea",
            ]
        case .hackerNews:
            titleSelectors = ["input[name=\"title\"]"]
            bodySelectors = ["textarea[name=\"text\"]", "textarea"]
        case .technical:
            titleSelectors = [
                "input[name=\"title\"]",
                "input[placeholder*=\"标题\"]",
                "input[placeholder*=\"title\" i]",
            ]
            bodySelectors = [
                "textarea[name=\"content\"]",
                "textarea",
                "div[contenteditable=\"true\"]",
            ]
        case .longform:
            titleSelectors = [
                "input[placeholder*=\"标题\"]",
                "input[name=\"title\"]",
                "input[placeholder*=\"title\" i]",
            ]
            bodySelectors = [
                "div[contenteditable=\"true\"]",
                "textarea",
            ]
        }
        let titleArray = jsArray(titleSelectors)
        let bodyArray = jsArray(bodySelectors)
        return """
        (function(){
          var titleSels = \(titleArray);
          var bodySels = \(bodyArray);
          function pick(sels) {
            for (var i = 0; i < sels.length; i++) {
              try {
                var el = document.querySelector(sels[i]);
                if (el) { return el; }
              } catch (e) {}
            }
            return null;
          }
          function setValue(el, text) {
            if (!el || !text) { return; }
            el.focus();
            if (el.isContentEditable) {
              el.innerText = text;
              el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: text}));
              return;
            }
            var proto = el.tagName === 'TEXTAREA'
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            try {
              var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
              setter.call(el, text);
            } catch (e) { el.value = text; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          }
          var titleEl = pick(titleSels);
          var bodyEl = pick(bodySels);
          if (titleEl === bodyEl) { bodyEl = null; }
          setValue(titleEl, \(JSString.literal(title)));
          setValue(bodyEl, \(JSString.literal(body)));
          return JSON.stringify({title: !!titleEl, body: !!bodyEl});
        })();
        """
    }

    private static func jsArray(_ values: [String]) -> String {
        "[" + values.map(JSString.literal).joined(separator: ", ") + "]"
    }
}
