import Combine
import os
import Foundation
import WebKit

@MainActor
class SafariExtensionStore: ObservableObject {
    @Published var extensions: [SafariExtension] = []

    var installedExtensions: [SafariExtension] { extensions.filter { $0.bundleURL != nil } }
    var enabledExtensions: [SafariExtension] { extensions.filter { $0.isEnabled } }

    private let saveKey = "desire.safariExtensions"
    private var messageHandlers: [UUID: WKScriptMessageHandler] = [:]

    init() {
        load()
    }

    // MARK: - Installation

    func installExtension(from url: URL) throws {
        let extension_ = try SafariExtensionImporter.importExtension(from: url)
        extensions.append(extension_)
        save()

        // 请求权限
        if extension_.needsPermissionRequest || extension_.needsHostPermissionRequest {
            requestPermissions(for: extension_)
        }
    }

    func uninstallExtension(_ extension_: SafariExtension) {
        // 清理消息处理器
        messageHandlers.removeValue(forKey: extension_.id)

        // 删除扩展文件
        if let bundleURL = extension_.bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }

        extensions.removeAll { $0.id == extension_.id }
        save()
    }

    // MARK: - State Management

    func enableExtension(_ extension_: SafariExtension) {
        guard let i = extensions.firstIndex(where: { $0.id == extension_.id }) else { return }
        extensions[i].isEnabled = true
        save()
    }

    func disableExtension(_ extension_: SafariExtension) {
        guard let i = extensions.firstIndex(where: { $0.id == extension_.id }) else { return }
        extensions[i].isEnabled = false
        save()
    }

    func grantPermissions(_ extension_: SafariExtension, permissions: Set<String>, hostPermissions: Set<String>) {
        guard let i = extensions.firstIndex(where: { $0.id == extension_.id }) else { return }
        extensions[i].permissionsGranted.formUnion(permissions)
        extensions[i].hostPermissionsGranted.formUnion(hostPermissions)
        save()
    }

    // MARK: - Content Script Injection

    func injectContentScripts(into webView: WKWebView, for url: URL) {
        let matched = matchingExtensions(for: url)

        for extension_ in matched where extension_.isEnabled {
            do {
                let (js, css) = try SafariExtensionImporter.loadContentScript(for: extension_)
                injectJS(js, into: webView)
                injectCSS(css, into: webView)
            } catch {
                Log.extensions.error("failed to load content scripts for \(extension_.localizedName): \(error.localizedDescription)")
            }
        }
    }

    private func injectJS(_ scripts: [String], into webView: WKWebView) {
        for script in scripts {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func injectCSS(_ styles: [String], into webView: WKWebView) {
        for css in styles {
            let js = """
            (function() {
                var style = document.createElement('style');
                style.textContent = '\(css)';
                document.head.appendChild(style);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Background Script Execution

    func startBackgroundScript(for extension_: SafariExtension, in webView: WKWebView) {
        do {
            guard let script = try SafariExtensionImporter.loadBackgroundScript(for: extension_) else { return }

            // 注入 Web Extensions API
            let apiScript = generateWebExtensionsAPI(extension_: extension_)
            webView.evaluateJavaScript(apiScript, completionHandler: nil)

            // 执行 background script
            webView.evaluateJavaScript(script, completionHandler: nil)
        } catch {
            Log.extensions.error("failed to load background script for \(extension_.localizedName): \(error.localizedDescription)")
        }
    }

    private func generateWebExtensionsAPI(extension_: SafariExtension) -> String {
        return """
        // Web Extensions API Stub
        window.chrome = {
            runtime: {
                id: '\(extension_.id.uuidString)',
                sendMessage: function(message) {
                    window.webkit.messageHandlers.extension\(extension_.id.uuidString.replacingOccurrences(of: "-", with: "")).postMessage(message);
                },
                onMessage: {
                    addListener: function(callback) {
                        window.__extensionMessageHandler = callback;
                    }
                }
            },
            tabs: {
                query: function(queryInfo, callback) {
                    // Stub implementation
                    if (callback) callback([]);
                },
                sendMessage: function(tabId, message) {
                    // Stub implementation
                }
            },
            storage: {
                local: {
                    get: function(keys, callback) {
                        // Stub implementation
                        if (callback) callback({});
                    },
                    set: function(items, callback) {
                        // Stub implementation
                        if (callback) callback();
                    }
                }
            }
        };

        window.browser = window.chrome;
        """
    }

    // MARK: - URL Matching

    private func matchingExtensions(for url: URL) -> [SafariExtension] {
        extensions.filter { extension_ in
            guard extension_.isEnabled else { return false }

            guard let contentScripts = extension_.manifest.content_scripts else { return false }

            for script in contentScripts {
                let included = script.matches.contains { matchPattern(url: url, pattern: $0) }
                let excluded = script.exclude_matches?.contains { matchPattern(url: url, pattern: $0) } ?? false

                if included && !excluded { return true }
            }

            return false
        }
    }

    private func matchPattern(url: URL, pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        if pattern == "*" { return true }

        let urlStr = url.absoluteString

        // 将 match pattern 转换为正则表达式
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "/", with: "\\/")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        return urlStr.range(of: "^" + regexPattern + "$", options: .regularExpression) != nil
    }

    // MARK: - Permissions

    private func requestPermissions(for extension_: SafariExtension) {
        // 这里应该显示一个权限请求对话框
        // 目前自动授予所有请求的权限
        let permissions = Set(extension_.requiredPermissions)
        let hostPermissions = Set(extension_.requiredHostPermissions)
        grantPermissions(extension_, permissions: permissions, hostPermissions: hostPermissions)
    }

    // MARK: - Persistence

    private func load() {
        if let decoded = DiskStore.load([SafariExtension].self, key: saveKey) {
            extensions = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SafariExtension].self, from: data) {
            extensions = decoded
            save()
            UserDefaults.standard.removeObject(forKey: saveKey)
        }
    }

    private func save() {
        DiskStore.save(extensions, key: saveKey)
    }
}