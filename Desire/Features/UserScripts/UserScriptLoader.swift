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
        func add(_ name: String, at time: WKUserScriptInjectionTime, mainFrameOnly: Bool = false) {
            let source = load(name)
            guard !source.isEmpty else { return }
            scripts.append(WKUserScript(source: source, injectionTime: time, forMainFrameOnly: mainFrameOnly))
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
        add("dom-tools", at: .atDocumentStart)
        add("selection-ai", at: .atDocumentEnd, mainFrameOnly: true)
        add("audio-state", at: .atDocumentEnd)
        add("password-detect", at: .atDocumentEnd)
        add("reader-content", at: .atDocumentEnd)
        add("hover-link", at: .atDocumentEnd)
        add("middle-click", at: .atDocumentEnd)
        return scripts
    }

    static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            Log.userScripts.error("resource not found — UserScripts/\(name, privacy: .public).js")
            return ""
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.userScripts.error("failed to read UserScripts/\(name, privacy: .public).js: \(error.localizedDescription)")
            return ""
        }
    }

    /// WebExtension API runtime — injected in the ISOLATED
    /// `desireExtensions` content world so page JS can neither see nor
    /// spoof `browser.*`. Plugin code (PluginStore) evaluates in the same
    /// world; the DOM is shared, JS globals are not.
    static func extensionAPIScript() -> WKUserScript? {
        let source = load("webext-api")
        guard !source.isEmpty else { return nil }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: WebView.extensionWorld
        )
    }
}
