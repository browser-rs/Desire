import Combine
import Foundation
import WebKit

@MainActor
class PluginStore: ObservableObject {
    @Published var plugins: [Plugin] = []
    private let saveKey = "desire.plugins"

    init() { load() }

    func add(_ plugin: Plugin) {
        plugins.append(plugin)
        save()
    }

    func update(_ plugin: Plugin) {
        guard let i = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[i] = plugin
        save()
    }

    func remove(_ plugin: Plugin) {
        plugins.removeAll { $0.id == plugin.id }
        save()
        // Chrome 语义：卸载即清该插件的 storage.local 桶（0.3.3）。
        WebExtensionStore.clear(ext: plugin.id.uuidString)
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
    }

    /// 手动运行一次（工具栏固定图标点击）：绕过 URL 匹配直接在当前页
    /// 注入（隔离世界）。返回是否确有代码执行。
    @discardableResult
    func runOnce(_ plugin: Plugin, in webView: WKWebView) -> Bool {
        guard plugin.isEnabled, !plugin.jsCode.isEmpty else { return false }
        webView.evaluateJavaScript(
            "window.__desireExtID = '\(plugin.id.uuidString)';\n" + plugin.jsCode,
            in: nil, in: WebView.extensionWorld, completionHandler: nil)
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

    func inject(into webView: WKWebView, for url: URL) {
        let (js, css) = injectionCode(for: url)

        for (plugin, code) in css {
            let escaped = code
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            webView.evaluateJavaScript("""
            (function() {
                var s = document.createElement('style');
                s.textContent = '\(escaped)';
                document.head.appendChild(s);
            })();
            """, completionHandler: nil)
        }

        for (plugin, code, runAt) in js {
            let delay = runAt == .documentIdle ? 200 : 0
            // 注入前置插件身份（0.3.3）：storage 等 API 按此命名空间。
            let prologue = "window.__desireExtID = '\(plugin.id.uuidString)';\n"
            if delay > 0 {
                let escaped = code
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                // 插件跑在隔离 desireExtensions world（0.2.13）：可访问
                // browser.* 与页面 DOM，但页面 JS 看不到插件的全局。
                webView.evaluateJavaScript(
                    prologue + "setTimeout(function() { \(escaped) }, \(delay))",
                    in: nil, in: WebView.extensionWorld, completionHandler: nil)
            } else {
                webView.evaluateJavaScript(
                    prologue + code, in: nil, in: WebView.extensionWorld, completionHandler: nil)
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
