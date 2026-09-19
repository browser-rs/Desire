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
    }

    func matchingPlugins(for url: URL) -> [Plugin] {
        plugins.filter { p in
            guard p.isEnabled else { return false }
            let included = p.urlPatterns.isEmpty || matches(url: url, patterns: p.urlPatterns)
            let excluded = !p.excludePatterns.isEmpty && matches(url: url, patterns: p.excludePatterns)
            return included && !excluded
        }
    }

    func injectionCode(for url: URL) -> (js: [(code: String, runAt: RunAt)], css: [String]) {
        let matched = matchingPlugins(for: url)
        let js = matched.filter { !$0.jsCode.isEmpty }.map { ($0.jsCode, $0.runAt) }
        let css = matched.filter { !$0.cssCode.isEmpty }.map { $0.cssCode }
        return (js, css)
    }

    func inject(into webView: WKWebView, for url: URL) {
        let (js, css) = injectionCode(for: url)

        for code in css {
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

        for (code, runAt) in js {
            let delay = runAt == .documentIdle ? 200 : 0
            if delay > 0 {
                let escaped = code
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                // 插件跑在隔离 desireExtensions world（0.2.13）：可访问
                // browser.* 与页面 DOM，但页面 JS 看不到插件的全局。
                webView.evaluateJavaScript(
                    "setTimeout(function() { \(escaped) }, \(delay))",
                    in: nil, in: WebView.extensionWorld, completionHandler: nil)
            } else {
                webView.evaluateJavaScript(
                    code, in: nil, in: WebView.extensionWorld, completionHandler: nil)
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
