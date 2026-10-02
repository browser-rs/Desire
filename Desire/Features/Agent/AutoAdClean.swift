import Foundation
import os
import WebKit

/// AI 自动广告清理（2026-10-02，用户验证 findAdCandidates+blockElements 效果好
/// 之后的增强）：开关开启时，页面加载完成自动扫描广告候选，**高置信度**
/// （理由 ≥2 条）的自动走与 agent 相同的 blockElements 通道拦下——按 host
/// 生效、下次导航自动注入、进 ElementBlockStore 可 unblock 回滚。
///
/// 防误杀与防拉锯：
/// - 单一理由（class/id 等）不够定罪——自动拦截只收 ≥2 条独立理由的候选；
/// - 用户对某 host 手动 unblock 过 → 该 host 加入自动豁免名单，不再自动拦
///   （否则"用户拆、AI 又拦回去"的拉锯）；
/// - 同一 URL 一次页面加载只扫一次。
@MainActor
final class AutoAdClean {
    static let shared = AutoAdClean()
    static let log = Log.agent

    static let enabledKey = "aiAutoAdClean"
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 自动拦截被用户豁免的 host（unblockElement 时记入）。
    private static let exemptKey = "aiAutoAdClean.exemptHosts"
    private var exemptHosts: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: AutoAdClean.exemptKey) ?? [])
    /// 本会话已自动处理过的 URL（一次加载只扫一次）。
    private var handledURLs: Set<String> = []

    private init() {}

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AutoAdClean.enabledKey)
        let state = enabled ? "enabled" : "disabled"
        Self.log.info("auto ad clean \(state, privacy: .public)")
    }

    func exemptHost(_ host: String) {
        guard !host.isEmpty else { return }
        exemptHosts.insert(host.lowercased())
        UserDefaults.standard.set(Array(exemptHosts), forKey: AutoAdClean.exemptKey)
    }

    func isExempt(_ host: String) -> Bool {
        exemptHosts.contains(host.lowercased())
    }

    /// 页面加载完成钩子（ContentView onPageFinished 调用）。全部异步静默，
    /// 任何失败不影响页面。
    func handlePageLoad(webView: BrowserWKWebView, url: URL) {
        guard Self.isEnabled else { return }
        guard url.scheme == "http" || url.scheme == "https" else { return }
        guard let host = url.host, !host.isEmpty else { return }
        if isExempt(host) { return }
        let key = url.absoluteString
        guard !handledURLs.contains(key) else { return }
        handledURLs.insert(key)
        if handledURLs.count > 200 {
            handledURLs = Set(handledURLs.suffix(100))
        }

        Self.log.info("auto ad clean: scanning \(host, privacy: .public) (\(url.absoluteString.prefix(80), privacy: .public))")
        Task { [weak self] in
            await self?.scanAndClean(webView: webView, host: host)
        }
    }

    /// 扫描 → 高置信度候选自动 block（与 agent blockElements 同通道；
    /// ElementBlockStore 走 AppState.live，与 agent 工具同一份规则库）。
    func scanAndClean(webView: BrowserWKWebView, host: String) async {
        guard let elementBlockStore = AppState.live?.elementBlockStore else { return }
        let script = UserScriptLoader.load("ad-candidates")
        guard !script.isEmpty else { return }
        do {
            let raw = try await webView.callAsyncJavaScript(
                script,
                arguments: ["maxItems": 25],
                in: nil,
                contentWorld: .page
            ) as? String
            guard let raw,
                  let data = raw.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = payload["candidates"] as? [[String: Any]]
            else { return }

            // 高置信度门槛：≥2 条独立理由（单理由误杀率高——class/id 撞名、
            // slot-size 撞布局）。与 agent 人工挑选互补：这里只收稳的。
            let confident = candidates
                .filter { ($0["reasons"] as? [String] ?? []).count >= 2 }
                .compactMap { $0["selector"] as? String }
                .filter { !$0.isEmpty }
            guard !confident.isEmpty else {
                Self.log.info("auto ad clean: \(candidates.count, privacy: .public) candidate(s), none at high confidence")
                return
            }

            // 与 agent 的 blockElements 同通道：ElementBlockStore + 即时 CSS。
            var applied = 0
            for selector in confident.prefix(20) {
                if elementBlockStore.rules.contains(where: {
                    $0.cssSelector == selector && $0.urlPattern == host
                }) { continue }
                elementBlockStore.add(cssSelector: selector, urlPattern: host)
                applied += 1
            }
            guard applied > 0 else { return }
            let css = confident.map { "\($0) { display: none !important; }" }.joined()
            let escaped = css
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            _ = try? await webView.callAsyncJavaScript("""
            (function() {
                var style = document.getElementById('desire-blocked-selectors') || document.createElement('style');
                style.id = 'desire-blocked-selectors';
                style.textContent = (style.textContent || '') + '\(escaped)';
                if (!style.parentNode) document.head.appendChild(style);
                return 'ok';
            })();
            """, arguments: [:], in: nil, contentWorld: .page)
            Self.log.info("auto ad clean: blocked \(applied, privacy: .public) element(s) on \(host, privacy: .public)")
        } catch {
            Self.log.debug("auto ad clean scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
