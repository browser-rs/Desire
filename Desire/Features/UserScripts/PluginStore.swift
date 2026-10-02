import Combine
import Foundation
import WebKit

@MainActor
class PluginStore: ObservableObject {
    @Published var plugins: [Plugin] = []
    private let saveKey = "desire.plugins"

    /// R2 归一：background 运行时经此感知增/改/删/启停并对账
    /// （AppState 接线到 PluginBackgroundRuntime.syncAll）。
    var onPluginsChanged: (() -> Void)?

    init() { load() }

    func add(_ plugin: Plugin) {
        plugins.append(plugin)
        save()
        onPluginsChanged?()
    }

    func update(_ plugin: Plugin) {
        guard let i = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[i] = plugin
        save()
        onPluginsChanged?()
    }

    func remove(_ plugin: Plugin) {
        plugins.removeAll { $0.id == plugin.id }
        save()
        onPluginsChanged?()
        // Chrome 语义：卸载即清该插件的 storage.local 桶（0.3.3）。
        WebExtensionStore.clear(ext: plugin.id.uuidString)
        // 包资源目录一并清理（chrome.scripting files[] 的文件来源）。
        PluginResources.discard(plugin.resourcesPath)
    }

    /// 工具栏固定切换（0.2.17 Chrome 式扩展面板）。
    func togglePin(_ id: UUID) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].pinned = !(plugins[i].isPinned)
        save()
    }

    /// 显式设定固定状态（桥用）。
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].pinned = pinned
        save()
    }

    /// 启用/停用（面板与桥共用；停用后不再自动注入，固定图标同步隐藏）。
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].isEnabled = enabled
        save()
        onPluginsChanged?()
    }

    /// 手动运行一次（工具栏固定图标点击）：绕过 URL 匹配直接在当前页
    /// 注入（隔离世界）。返回是否确有代码执行。
    @discardableResult
    func runOnce(_ plugin: Plugin, in webView: WKWebView) -> Bool {
        guard plugin.isEnabled, !plugin.jsCode.isEmpty else { return false }
        webView.evaluateJavaScript(
            "window.__desireExtID = '\(plugin.id.uuidString)';\n" + plugin.jsCode,
            in: nil, in: WebView.pluginWorld(plugin.id), completionHandler: nil)
        return true
    }

    func matchingPlugins(for url: URL) -> [Plugin] {
        plugins.filter { p in
            guard p.isEnabled else { return false }
            let included = p.urlPatterns.isEmpty || matches(url: url, patterns: p.urlPatterns)
            let excluded = !p.excludePatterns.isEmpty && matches(url: url, patterns: p.excludePatterns)
            return included && !excluded
        }
    }

    func injectionCode(for url: URL) -> (js: [(plugin: Plugin, code: String, runAt: RunAt)], css: [(plugin: Plugin, code: String)]) {
        let matched = matchingPlugins(for: url)
        let js = matched.filter { !$0.jsCode.isEmpty }.map { ($0, $0.jsCode, $0.runAt) }
        let css = matched.filter { !$0.cssCode.isEmpty }.map { ($0, $0.cssCode) }
        return (js, css)
    }

    func inject(into webView: WKWebView, for url: URL, tabID: UUID? = nil) {
        let (js, css) = injectionCode(for: url)

        for (_, code) in css {
            webView.evaluateJavaScript("""
            (function() {
                var s = document.createElement('style');
                s.textContent = \(JSString.literal(code));
                document.head.appendChild(s);
            })();
            """, completionHandler: nil)
        }

        for (plugin, code, runAt) in js {
            // **WebKit 会吞掉导航收尾头 ~50ms 里新文档发出的脚本消息**
            //（2026-10-02 实测：didFinish 拍 evaluate 注入的代码，立即
            // postMessage 丢失、setTimeout(0) 也丢、50ms 起存活）——
            // document_end 包一层 60ms 延时再跑插件体，否则 runtime.sendMessage/
            // connect 的首发消息必丢。document_idle 原有 200ms 天然安全。
            let delay = runAt == .documentIdle ? 200 : (runAt == .documentEnd ? 60 : 0)
            // 前置：插件身份 + **webext-api 运行时**。user script 是 webview
            // 定格的——插件装在 webview 创建之后就只有这条路能保证该 world
            // 里有 chrome.*（脚本自带 __desireExt 防重入，幂等）。
            let runtime = UserScriptLoader.load("webext-api")
            let prologue = (runtime.isEmpty ? "" : runtime + "\n")
                + "window.__desireExtID = '\(plugin.id.uuidString)';\n"
            if delay > 0 {
                // ⚠️ 这里是**函数体**位置，不是字符串字面量——做过一段时间的
                // `\'` 转义会把任何含单引号的插件代码变成 SyntaxError（函数体里
                // `\'` 是非法 token，实测 BUG-2）。与 document_end 分支一样裸注入。
                // 插件跑在**每插件独立 world**：可访问 browser.* 与页面 DOM，
                // 但页面 JS 看不到插件的全局；插件之间也互相隔离。
                webView.evaluateJavaScript(
                    prologue + "setTimeout(function() { \(code) }, \(delay))",
                    in: nil, in: WebView.pluginWorld(plugin.id), completionHandler: nil)
            } else {
                webView.evaluateJavaScript(
                    prologue + code, in: nil, in: WebView.pluginWorld(plugin.id), completionHandler: nil)
            }
        }
    }

    // MARK: - URL matching (Greasemonkey-style)

    private func matches(url: URL, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pattern == "*" { return true }
            if pattern == "*://*/*" { return true }
            let str = url.absoluteString
            if globMatch(str, pattern: pattern) { return true }
            // Chrome match-pattern 语法不允许带端口——带端口的 URL 也必须命中
            // 无端口 pattern（*://127.0.0.1/* 要能匹配 127.0.0.1:8877/*）。
            if let host = url.host, let port = url.port {
                let needle = "\(host):\(port)"
                if let range = str.range(of: needle) {
                    let portless = str.replacingCharacters(in: range, with: host)
                    if globMatch(portless, pattern: pattern) { return true }
                }
            }
        }
        return false
    }

    private func globMatch(_ str: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let regex = "^" + escaped
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        + "$"
        return str.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Import / Export

    private static let pluginUTI = "me.siwi.Desire.plugin"

    func exportPlugin(_ plugin: Plugin) -> URL? {
        guard let data = try? JSONEncoder().encode(plugin) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(plugin.name).desireplugin")
        try? data.write(to: url)
        return url
    }

    func importPlugin(from url: URL) -> Plugin? {
        guard let data = try? Data(contentsOf: url),
              let plugin = try? JSONDecoder().decode(Plugin.self, from: data) else { return nil }
        return plugin
    }

    // MARK: - Persistence

    private func load() {
        if let decoded = DiskStore.load([Plugin].self, key: saveKey) {
            plugins = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([Plugin].self, from: data) {
            plugins = decoded
            save()
            UserDefaults.standard.removeObject(forKey: saveKey)
        }
    }

    private func save() {
        DiskStore.save(plugins, key: saveKey)
    }
}
