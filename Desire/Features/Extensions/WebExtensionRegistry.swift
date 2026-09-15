import Combine
import Foundation
import os
import WebKit

/// Registry for installed WebExtensions: install/unpackaged folders, persist
/// security-scoped bookmarks, inject content scripts into the extension's
/// isolated content world, and back `chrome.storage.local` natively.
///
/// v0.1 scope: content scripts + chrome.storage + chrome.runtime.getManifest.
/// Background pages / service workers / browser actions / webRequest are not
/// implemented (WKWebView cannot run MV3 service workers; declarative
/// blocking is covered separately by the filter-list system).
@MainActor
class WebExtensionRegistry: ObservableObject {
    static let shared = WebExtensionRegistry()

    @Published private(set) var extensions: [WebExtension] = []

    private var folderURLs: [UUID: URL] = [:]
    private var scopedAccess: [UUID: URL] = [:]
    private var worlds: [String: WKContentWorld] = [:]
    private var storageCaches: [String: [String: Any]] = [:]

    private let storageKey = "webExtensions"
    private let messageHandlerName = "webextStorage"

    private init() {
        extensions = DiskStore.load([WebExtension].self, key: storageKey) ?? []
        for ext in extensions {
            resolveFolder(for: ext)
        }
    }

    // MARK: - Install / manage

    /// Installs an unpacked extension folder (must contain manifest.json).
    /// Returns an error message on failure, nil on success.
    @discardableResult
    func install(at folder: URL) -> String? {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return "manifest.json not found in the selected folder"
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let manifest = try? decoder.decode(WebExtensionManifest.self, from: data) else {
            return "Invalid manifest.json"
        }

        let id = UUID()
        var ext = WebExtension(
            id: id,
            name: manifest.name ?? folder.lastPathComponent,
            version: manifest.version ?? "0.0",
            folderBookmark: Data(),
            isEnabled: true,
            contentScripts: manifest.contentScripts ?? [],
            manifestJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
        // Retain access to the user-picked folder across launches.
        let started = folder.startAccessingSecurityScopedResource()
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope]) {
            ext.folderBookmark = bookmark
        }
        if started {
            scopedAccess[id] = folder
        }
        folderURLs[id] = folder
        extensions.append(ext)
        save()
        Log.extensions.info("WebExtension \(ext.name, privacy: .public) installed (\(ext.contentScripts.count) content script block(s))")
        return nil
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let i = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[i].isEnabled = enabled
        save()
    }

    func remove(_ id: UUID) {
        if let url = scopedAccess[id] {
            url.stopAccessingSecurityScopedResource()
        }
        scopedAccess[id] = nil
        folderURLs[id] = nil
        worlds.removeValue(forKey: id.uuidString)
        storageCaches[id.uuidString] = nil
        try? FileManager.default.removeItem(at: storageDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        extensions.removeAll { $0.id == id }
        save()
    }

    private func resolveFolder(for ext: WebExtension) {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: ext.folderBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            Log.extensions.error("WebExtension \(ext.name, privacy: .public): folder bookmark unreadable")
            return
        }
        if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) {
            if let i = extensions.firstIndex(where: { $0.id == ext.id }) {
                extensions[i].folderBookmark = refreshed
            }
        }
        let started = url.startAccessingSecurityScopedResource()
        if started {
            scopedAccess[ext.id] = url
        }
        folderURLs[ext.id] = url
    }

    private func save() {
        DiskStore.save(extensions, key: storageKey)
    }

    // MARK: - Content script injection

    /// Injects matching content scripts + the chrome.* bridge into the
    /// extension's isolated content world. Called at page load finish —
    /// document_start injection is a known v0.1 limitation.
    func injectContentScripts(into webView: WKWebView, for url: URL) {
        for ext in extensions where ext.isEnabled {
            guard let folder = folderURLs[ext.id] else { continue }
            let matched = ext.contentScripts.filter { WebExtensionMatcher.matches($0.matches, url: url) }
            guard !matched.isEmpty else { continue }
            let world = contentWorld(for: ext.id.uuidString)

            // chrome.* bridge (idempotent per world)
            webView.evaluateJavaScript(Self.chromeBridgeScript(extID: ext.id.uuidString, manifestJSON: ext.manifestJSON),
                                       in: nil, in: world, completionHandler: nil)

            for script in matched {
                for jsFile in script.js {
                    guard let source = try? String(contentsOf: folder.appendingPathComponent(jsFile), encoding: .utf8) else { continue }
                    webView.evaluateJavaScript(source, in: nil, in: world, completionHandler: nil)
                }
                for cssFile in script.css {
                    // Styles affect the shared DOM even from an isolated world.
                    guard let css = try? String(contentsOf: folder.appendingPathComponent(cssFile), encoding: .utf8) else { continue }
                    let js = "(function(){var s=document.createElement('style');s.textContent='\(css.replacingOccurrences(of: "'", with: "\\'"))';document.head.appendChild(s);})();"
                    webView.evaluateJavaScript(js, in: nil, in: world, completionHandler: nil)
                }
            }
            Log.extensions.info("injected content scripts for \(ext.name, privacy: .public) on \(url.host ?? "", privacy: .public)")
        }
    }

    private func contentWorld(for extID: String) -> WKContentWorld {
        if let world = worlds[extID] { return world }
        let world = WKContentWorld.world(name: "webext-" + extID)
        worlds[extID] = world
        return world
    }

    // MARK: - chrome.storage.local backend

    func handleStorageMessage(_ dict: [String: Any], reply: @escaping (WKContentWorld, String) -> Void) {
        guard let extID = dict["ext"] as? String,
              let op = dict["op"] as? String,
              let id = (dict["id"] as? NSNumber)?.intValue else { return }
        let payload = dict["payload"]

        Task { @MainActor in
            let result = await storageResult(op: op, extID: extID, payload: payload)
            let world = contentWorld(for: extID)
            let payloadData: String
            if let data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result ?? NSNull()]),
               let string = String(data: data, encoding: .utf8) {
                payloadData = string
            } else {
                payloadData = "{\"id\":\(id),\"result\":null}"
            }
            reply(world, "window.__desireExtReply && window.__desireExtReply(\(payloadData))")
        }
    }

    private func storageResult(op: String, extID: String, payload: Any?) async -> Any? {
        var cache = await loadStorage(extID: extID)
        switch op {
        case "get":
            return storageGet(cache, payload: payload)
        case "set":
            guard let items = payload as? [String: Any] else { return nil }
            for (k, v) in items { cache[k] = v }
            await saveStorage(extID: extID, cache: cache)
        case "remove":
            if let keys = payload as? [String] {
                for k in keys { cache.removeValue(forKey: k) }
            } else if let key = payload as? String {
                cache.removeValue(forKey: key)
            }
            await saveStorage(extID: extID, cache: cache)
        case "clear":
            await saveStorage(extID: extID, cache: [:])
        default:
            break
        }
        return nil
    }

    private func storageGet(_ cache: [String: Any], payload: Any?) -> [String: Any?] {
        switch payload {
        case nil:
            return cache.mapValues { Optional($0) }
        case let key as String:
            return [key: cache[key]]
        case let keys as [String]:
            var out: [String: Any?] = [:]
            for k in keys { out[k] = cache[k] }
            return out
        case let defaults as [String: Any]:
            var out: [String: Any?] = defaults.mapValues { Optional($0) }
            for (k, v) in cache { out[k] = v }
            return out
        default:
            return [:]
        }
    }

    private func loadStorage(extID: String) async -> [String: Any] {
        if let cached = storageCaches[extID] { return cached }
        let file = storageDirectory.appendingPathComponent(extID, isDirectory: true)
            .appendingPathComponent("storage.json")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        storageCaches[extID] = dict
        return dict
    }

    private func saveStorage(extID: String, cache: [String: Any]) async {
        storageCaches[extID] = cache
        let dir = storageDirectory.appendingPathComponent(extID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("storage.json"), options: .atomic)
        }
    }

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Desire", isDirectory: true).appendingPathComponent("extensions", isDirectory: true)
    }

    // MARK: - chrome.* bridge script

    nonisolated static func chromeBridgeScript(extID: String, manifestJSON: String) -> String {
        let quotedManifest = (try? JSONSerialization.data(withJSONObject: [manifestJSON]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"{}\""
        return """
        (function() {
            if (window.__desireExtBridgeInstalled) return;
            window.__desireExtBridgeInstalled = true;
            const extID = "\(extID)";
            const handlers = {};
            let cbSeq = 0;
            function native(op, payload) {
                return new Promise(function(resolve) {
                    cbSeq += 1;
                    const cbId = cbSeq;
                    handlers[cbId] = resolve;
                    window.webkit.messageHandlers.webextStorage.postMessage({ ext: extID, op: op, id: cbId, payload: payload === undefined ? null : payload });
                });
            }
            window.__desireExtReply = function(id, result) {
                if (handlers[id]) { handlers[id](result); delete handlers[id]; }
            };
            const manifest = \(quotedManifest);
            const runtime = {
                id: extID,
                getManifest: function() { return manifest; },
                sendMessage: function(message, cb) { if (cb) cb(); }
            };
            const local = {
                get: function(keys, cb) { native("get", keys === undefined ? null : keys).then(function(r) { if (cb) cb(r); }); },
                set: function(items, cb) { native("set", items).then(function() { if (cb) cb(); }); },
                remove: function(keys, cb) { native("remove", keys).then(function() { if (cb) cb(); }); },
                clear: function(cb) { native("clear", null).then(function() { if (cb) cb(); }); }
            };
            local.sync = local;
            window.chrome = window.chrome || {};
            window.chrome.runtime = runtime;
            window.chrome.storage = { local: local, sync: local };
        })();
        """
    }
}
