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
        // 大页面守护 + 性能快照数据面（0.6.4）：DOM 节点数 + long task 计数
        add("page-perf", at: .atDocumentEnd)
        // 视频速度控制数据面（0.6.5）：速率桥 + 徽章（默认 1x 零 UI）
        add("video-speed", at: .atDocumentEnd)
        // SPA 路由变化 → DPP 重解析（页面世界：必须包住页面自己的 history 调用）
        add("dpp-route-watch", at: .atDocumentStart)
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
        // dom-tools.js **只进隔离世界**（agentToolWorld）——页面世界不再注入
        // （第三轮审计指导 4：页面世界副本自工具求值迁移后只剩死代码；executeJS
        // 用户代码因此不再能引用 __desire* 函数——它们本就是实现细节）。
        // 页面世界仅保留 network-tools.js（__desireGetNetworkLog 读 network-monitor
        // 的页面世界状态；__desireWaitForNetworkIdle 猴补页面 XHR/fetch）。
        scripts.append(WKUserScript(source: load("dom-tools"), injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false, in: WebView.agentToolWorld))
        add("network-tools", at: .atDocumentStart)
        add("selection-ai", at: .atDocumentEnd, mainFrameOnly: true)
        // v0.7.29：网页工作流录制（主框架；宿主翻 __desireWorkflowRecording 才生效）。
        add("workflow-recorder", at: .atDocumentStart, mainFrameOnly: true)
        // v0.7.29：崩溃后的滚动位置恢复（节流上报，宿主按标签保存）。
        add("scroll-memory", at: .atDocumentEnd, mainFrameOnly: true)
        add("audio-state", at: .atDocumentEnd)
        add("super-drag", at: .atDocumentStart)
        add("password-detect", at: .atDocumentEnd)
        add("reader-content", at: .atDocumentEnd)
        add("hover-link", at: .atDocumentEnd)
        add("middle-click", at: .atDocumentEnd)
        // 右键增强（v0.8.31 批次一）：图片/链接/选区上拦原生菜单上报宿主。
        add("context-menu", at: .atDocumentEnd)
        // **in-page 广告篡改的两种历史形态**（2026-11-01 实验A实锤 → 2026-11-10 重做）：
        // · yt-anti-detect（给 window.ytInitialPlayerResponse 装 defineProperty
        //   陷阱）永久退役——属性描述符本身就是可探的改动面。
        // · yt-json-prune 重写后保留：**不再 hook JSON.parse**。YouTube 的
        //   `j.s_` 探针拿带广告字段的 canary JSON 重新 parse 做深度比对，任何
        //   "解析时删键"都会被判定；新实现只在 DOMContentLoaded 剪内嵌
        //   ytInitialPlayerResponse + 包 fetch（按 response.url 认 /youtubei/v1/player），
        //   不碰任何全局解析语义。检测面对照见脚本头注释。
        // 门控 = 内置广告拦截插件开关（与视频广告 CSS/反拦截脚本同一真相）；
        // 关掉内置拦截 = 纯浏览器，页面里一行都不注入。
        if PluginStore.liveBuiltInAdGuardEnabled {
            add("yt-json-prune", at: .atDocumentStart, mainFrameOnly: true)
        }
        // media-visibility-resume **退役（v0.8.32 稳定优先）**：它的页面内
        // play() 与 YouTube enforcement 拉锯，是"停了又播"振荡的来源。
        // 切回标签后的恢复交给 WebKit 自身的媒体恢复路径（Safari 同款）。
        // 暂停 oracle 常驻（v0.8.32）：PAUSE/consent-blocked 低噪事件 →
        // 设置 ▸ 自动播放诊断 + Log.autoplay。复发必有第一现场。
        add("media-pause-diag", at: .atDocumentEnd)
        // A/B 实测（自动播放专项）：临时禁 json-prune，验证"广告调度器等
        // 不到广告 → 暂停正片"假说。结论后还原。

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
