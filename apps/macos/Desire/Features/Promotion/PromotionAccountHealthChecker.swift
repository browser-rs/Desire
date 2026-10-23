import Foundation
import WebKit

/// 账号健康检查执行体（v0.8.3）：在**后台标签**打开渠道 composer，等页面
/// 加载后只读检查适配包声明的登录信号/账号视图/composer 是否存在，然后关掉
/// 标签。不读 Keychain、不发布、不提交任何表单。
@MainActor
enum PromotionAccountHealthChecker {
    static func check(channel: PromotionChannel,
                      adapter: DPPAdapter?) async -> PromotionAccountHealth.Assessment {
        let enabled = adapter.map { DPPAdapterStore.shared.isEnabled($0) } ?? false
        let declared = PromotionAccountHealth.declaredState(adapter: adapter, enabled: enabled)
        guard declared.state == .unknown, let adapter else { return declared }
        guard let raw = channel.composerURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else {
            return PromotionAccountHealth.Assessment(
                state: .unknown, detail: "No composer URL configured for this channel.",
                checkedAt: Date())
        }
        guard let manager = TabSessionCoordinator.shared.activeTabManager else {
            return PromotionAccountHealth.Assessment(
                state: .unknown, detail: "No active browser window.", checkedAt: Date())
        }
        let before = Set(manager.tabs.map(\.id))
        manager.addTab(url: url.absoluteString,
                       javaScriptEnabled: true,
                       contentBlocker: AppState.live?.contentBlocker,
                       makeActive: false)
        guard let tab = manager.tabs.first(where: { !before.contains($0.id) }) else {
            return PromotionAccountHealth.Assessment(
                state: .unknown, detail: "Could not open a check tab.", checkedAt: Date())
        }
        defer {
            if let index = manager.tabs.firstIndex(where: { $0.id == tab.id }) {
                manager.closeTab(at: index)
            }
        }
        let webView = tab.browser.webView
        guard await waitReady(webView) else {
            return PromotionAccountHealth.Assessment(
                state: .unknown, detail: "The check page did not finish loading.", checkedAt: Date())
        }
        let proto = adapter.protocolBody
        let login = proto.signals["opsLoginRequired"]
        let account = proto.views["opsAccount"]?.item
        let composer = proto.views["opsComposer"]?.item
        guard login != nil || account != nil || composer != nil else {
            return PromotionAccountHealth.Assessment(
                state: .noSignal,
                detail: "The adapter declares no login signal or account/composer view.",
                checkedAt: Date())
        }
        let value = try? await webView.evaluateJavaScript(
            statusScript(login: login, account: account, composer: composer))
        let rawValue = (value as? String) ?? "{}"
        let data = rawValue.data(using: .utf8) ?? Data()
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let assessment = PromotionAccountHealth.evaluate(
            loginMatched: parsed?["login"] as? Bool ?? false,
            accountItems: parsed?["account"] as? Int ?? 0,
            composerFound: parsed?["composer"] as? Bool ?? false)
        return PromotionAccountHealth.Assessment(
            state: assessment.state, detail: assessment.detail, checkedAt: Date())
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

    private static func statusScript(login: String?, account: String?, composer: String?) -> String {
        func literal(_ value: String?) -> String {
            value.map(JSString.literal) ?? "null"
        }
        return """
        (function(){
          var login = \(literal(login));
          var account = \(literal(account));
          var composer = \(literal(composer));
          function visible(sel) {
            var el = document.querySelector(sel);
            if (!el) return false;
            var r = el.getBoundingClientRect();
            var cs = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && cs.display !== 'none' && cs.visibility !== 'hidden';
          }
          return JSON.stringify({
            login: login ? visible(login) : false,
            account: account ? document.querySelectorAll(account).length : 0,
            composer: composer ? !!document.querySelector(composer) : false
          });
        })()
        """
    }
}
