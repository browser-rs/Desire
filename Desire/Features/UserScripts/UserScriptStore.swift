import Combine
import Foundation
import WebKit

@MainActor
class UserScriptStore: ObservableObject {
    @Published var scripts: [UserScript] = []
    private let saveKey = "desire.userscripts"

    init() {
        load()
    }

    func add(name: String, urlPattern: String, code: String) {
        let script = UserScript(id: UUID(), name: name, urlPattern: urlPattern, code: code, isEnabled: true)
        scripts.append(script)
        save()
    }

    func update(_ script: UserScript) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        save()
    }

    func remove(_ script: UserScript) {
        scripts.removeAll { $0.id == script.id }
        save()
    }

    func matchingScripts(for url: URL) -> [UserScript] {
        scripts.filter { script in
            guard script.isEnabled else { return false }
            let pattern = script.urlPattern
            if pattern.isEmpty || pattern == "*" { return true }
            let absoluteString = url.absoluteString
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                return absoluteString.hasPrefix(prefix)
            }
            return absoluteString.contains(pattern)
        }
    }

    func injectScripts(into webView: WKWebView) {
        guard let url = webView.url else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        for script in matchingScripts(for: url) {
            let userScript = WKUserScript(source: script.code, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            webView.configuration.userContentController.addUserScript(userScript)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([UserScript].self, from: data) else { return }
        scripts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}
