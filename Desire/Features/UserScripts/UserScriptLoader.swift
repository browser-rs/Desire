import Foundation
import os
import WebKit

/// Loads bundled JavaScript resources from `Desire/UserScripts/*.js`.
///
/// The project's file-system-synchronized group auto-includes non-Swift
/// files under `Desire/` as app-bundle resources, so every `.js` file in
/// `Desire/UserScripts/` is available via `Bundle.main` at runtime — no
/// pbxproj registration is required (same mechanism that bundles
/// `Localizable.xcstrings` and `Assets.xcassets`).
///
/// Usage:
/// ```
/// let js = UserScriptLoader.load("console-intercept")
/// ```
/// Pass the resource name **without** the `.js` extension.
///
/// On failure (missing file or bad encoding) this logs a clear diagnostic
/// and returns an empty string, so the caller's `WKUserScript` /
/// `evaluateJavaScript` path degrades gracefully rather than crashing.
/// A missing resource is always a build/packaging bug, not a user-facing
/// condition.
enum UserScriptLoader {
    /// Desire's own always-on user scripts, in injection order. Centralized
    /// here so the WebExtension registry can REBUILD the full set after
    /// enable/disable churn — WKUserContentController has no per-script
    /// removal API (only removeAllUserScripts), so rebuild is the only way.
    static func builtinScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        func add(_ name: String, at time: WKUserScriptInjectionTime, mainFrameOnly: Bool = false, world: WKContentWorld? = nil) {
            let source = load(name)
            guard !source.isEmpty else { return }
            if let world {
                scripts.append(WKUserScript(source: source, injectionTime: time,
                                            forMainFrameOnly: mainFrameOnly, in: world))
            } else {
                scripts.append(WKUserScript(source: source, injectionTime: time, forMainFrameOnly: mainFrameOnly))
            }
        }
        add("console-intercept", at: .atDocumentStart)
        // 曾在此注入 fullscreen-shim（覆盖 Element.prototype.requestFullscreen
        // 做纯 CSS "网页满屏"）。那正是"视频只有网页区域大小、四周黑边"的
        // 根因——覆盖掉原生 API 之后 WebKit 的全屏管线永远不跑，元素被 CSS
        // 钉在 webview 视口（= 窗口减去 chrome）里。原生 element fullscreen
        // 在本机实测完全正常（最小宿主对照实验：WebCoreFullScreenWindow，
        // 视口 = 屏幕 2560x1440；注入同一份 shim 后立刻退化成 DOM-only）。
        // 机制说明见 WebView.swift 的 fullscreen 注释。
        add("media-sniffer", at: .atDocumentStart)
        // DevTools ▸ Network：子资源计时 + fetch/XHR 钩子（见脚本头注释）。
        add("network-monitor", at: .atDocumentStart)
        add("dom-tools", at: .atDocumentStart)
        // 同一份函数注入 Agent 工具隔离世界（WebView.agentToolWorld）——工具
        // 求值与页面世界隔离，页面覆盖页面世界的同名函数影响不到工具（第二轮
        // 审计 P2-1）。页面世界副本保留：getNetworkLog/waitForNetworkIdle 依赖
        // network-monitor 的页面世界状态。
        scripts.append(WKUserScript(source: load("dom-tools"), injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false, in: WebView.agentToolWorld))
        add("selection-ai", at: .atDocumentEnd, mainFrameOnly: true)
        add("audio-state", at: .atDocumentEnd)
        add("password-detect", at: .atDocumentEnd)
        add("reader-content", at: .atDocumentEnd)
        add("hover-link", at: .atDocumentEnd)
        add("middle-click", at: .atDocumentEnd)
        return scripts
    }

    /// R2-3：打包资源运行期不变——缓存起来。此前每次导航的
    /// dark-mode/sponsorblock 注入（didFinish）和每个新标签的 builtinScripts()
    /// （10 个脚本约 90KB）都同步读盘，会话恢复时放大 N 倍。
    /// 竞争的最坏后果 = 并发重复读盘一次（幂等），故 unsafe + 免锁可接受。
    private nonisolated(unsafe) static var cache: [String: String] = [:]

    static func load(_ name: String) -> String {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            Log.userScripts.error("resource not found — UserScripts/\(name, privacy: .public).js")
            return ""
        }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            cache[name] = source
            return source
        } catch {
            Log.userScripts.error("failed to read UserScripts/\(name, privacy: .public).js: \(error.localizedDescription)")
            return ""
        }
    }

    /// WebExtension API runtime — injected in an ISOLATED content world
    /// (shared `desireExtensions` 或 per-plugin world，见 WebView.pluginWorld)
    /// so page JS can neither see nor spoof `browser.*`. Plugin code
    /// (PluginStore) evaluates in the same world; the DOM is shared, JS
    /// globals are not. **world 必须与运行插件的 world 一致**：曾经写死
    /// extensionWorld，per-plugin world 里 chrome.* 永远 undefined。
    static func extensionAPIScript(in world: WKContentWorld = WebView.extensionWorld) -> WKUserScript? {
        let source = load("webext-api")
        guard !source.isEmpty else { return nil }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        )
    }
}
