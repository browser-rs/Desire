import Combine
import Foundation
import os
import WebKit

/// Registry for installed WebExtensions: install/unpackaged folders, persist
/// security-scoped bookmarks, and inject content scripts as WKUserScripts
/// into per-extension isolated content worlds (document_start supported).
///
/// v0.3 scope: content scripts (start/end), chrome.storage.local,
/// chrome.runtime.getManifest / sendMessage / onMessage with a per-extension
/// OFFSCREEN background webview (background.page / background.scripts /
/// service_worker files all run in that page — service workers are NOT real
/// workers in WKWebView, simple ones still work), and browser-action popups
/// (default_popup) presented as floating panels.
///
/// Not implemented: webRequest, tabs.sendMessage (background→content),
/// options pages, i18n.
///
/// Injection is via `apply(to:)` at webview creation — user scripts take
/// effect on the tab's NEXT navigation. Enable/disable/install/remove
/// rebuild every registered controller (WKUserContentController has no
/// per-script removal; Desire's own builtins are re-added by
/// `UserScriptLoader.builtinScripts()` during the rebuild).
@MainActor
class WebExtensionRegistry: ObservableObject {
    static let shared = WebExtensionRegistry()

    static let storageHandlerName = "webextStorage"
    static let runtimeHandlerName = "webextRuntime"
    static let runtimeReplyHandlerName = "webextRuntimeReply"

    @Published private(set) var extensions: [WebExtension] = []
    /// Live background contexts, keyed by extension id.
    @Published private(set) var backgroundStates: [UUID: String] = [:]

    private var folderURLs: [UUID: URL] = [:]
    private var scopedAccess: [UUID: URL] = [:]
    private var worlds: [String: WKContentWorld] = [:]
    private var storageCaches: [String: [String: Any]] = [:]
    private var backgrounds: [UUID: WKWebView] = [:]
    private var popups: [UUID: NSPanel] = [:]
    /// Content-script runtime callbacks waiting for the background response.
    private var pendingResponses: [Int: (webView: WKWebView, world: WKContentWorld)] = [:]
    private var runtimeSeq = 0

    private struct WeakController { weak var controller: WKUserContentController? }
    private var registered: [WeakController] = []

    private let storageKey = "webExtensions"

    private init() {
        extensions = DiskStore.load([WebExtension].self, key: storageKey) ?? []
        for ext in extensions {
            resolveFolder(for: ext)
            if ext.isEnabled { ensureBackground(for: ext) }
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
            manifestJSON: String(data: data, encoding: .utf8) ?? "{}",
            popupPath: manifest.popupPath,
            backgroundPage: manifest.background?.page,
            backgroundScripts: manifest.backgroundScripts
        )
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
        rebuildAllUserScripts()
        if ext.hasBackground {
            ensureBackground(for: ext)
        }
        Log.extensions.info("WebExtension \(ext.name, privacy: .public) installed")
        return nil
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let i = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[i].isEnabled = enabled
        save()
        rebuildAllUserScripts()
        if let ext = extensions.first(where: { $0.id == id }) {
            if enabled { ensureBackground(for: ext) } else { teardownBackground(for: id) }
        }
        if !enabled { closePopup(for: id) }
    }

    func remove(_ id: UUID) {
        teardownBackground(for: id)
        closePopup(for: id)
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

    // MARK: - Content script distribution

    func apply(to config: WKWebViewConfiguration) {
        let controller = config.userContentController
        registered.removeAll { $0.controller == nil }
        registered.append(WeakController(controller: controller))
        applyUserScripts(to: controller)
    }

    private func applyUserScripts(to controller: WKUserContentController) {
        for script in UserScriptLoader.builtinScripts() {
            controller.addUserScript(script)
        }
        for ext in extensions where ext.isEnabled {
            for entry in userScriptEntries(for: ext) {
                controller.addUserScript(entry.script)
            }
        }
    }

    /// Full rebuild across every registered controller (enable/disable/
    /// install/remove churn — WKUserContentController has no per-script
    /// removal, so the whole set is rebuilt; Desire's builtins included).
    private func rebuildAllUserScripts() {
        registered.removeAll { $0.controller == nil }
        for box in registered {
            guard let controller = box.controller else { continue }
            applyUserScripts(to: controller)
        }
    }

    private func userScriptEntries(for ext: WebExtension) -> [(extID: String, script: WKUserScript)] {
        guard ext.isEnabled, let folder = folderURLs[ext.id] else { return [] }
        let world = contentWorld(for: ext.id.uuidString)
        var entries: [(extID: String, script: WKUserScript)] = []

        // chrome.* bridge before any content script.
        entries.append((extID: ext.id.uuidString, script: WKUserScript(
            source: Self.chromeBridgeScript(extID: ext.id.uuidString, manifestJSON: ext.manifestJSON),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        )))

        for script in ext.contentScripts {
            let time: WKUserScriptInjectionTime = script.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
            for jsFile in script.js {
                guard let source = try? String(contentsOf: folder.appendingPathComponent(jsFile), encoding: .utf8) else { continue }
                entries.append((extID: ext.id.uuidString, script: WKUserScript(
                    source: source,
                    injectionTime: time,
                    forMainFrameOnly: false,
                    in: world
                )))
            }
            for cssFile in script.css {
                guard let css = try? String(contentsOf: folder.appendingPathComponent(cssFile), encoding: .utf8) else { continue }
                let escaped = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                let js = "(function(){var s=document.createElement('style');s.textContent='\(escaped)';document.head.appendChild(s);})();"
                entries.append((extID: ext.id.uuidString, script: WKUserScript(
                    source: js,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false,
                    in: world
                )))
            }
        }
        return entries
    }

    // MARK: - Background context

    /// Lazily creates the offscreen background webview for an extension:
    /// `background.page` loads as HTML; `background.scripts` /
    /// `background.service_worker` are evaluated inside a generated wrapper
    /// page (service workers are NOT real workers here — simple ones work).
    @discardableResult
    private func ensureBackground(for ext: WebExtension) -> WKWebView {
        if let existing = backgrounds[ext.id] { return existing }
        let world = backgroundWorld(for: ext.id.uuidString)
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.storageHandlerName)
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.runtimeHandlerName)
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.runtimeReplyHandlerName)
        controller.addUserScript(WKUserScript(
            source: Self.backgroundBridgeScript(extID: ext.id.uuidString),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isHidden = true
        backgrounds[ext.id] = webView
        backgroundStates[ext.id] = "background running"

        guard let folder = folderURLs[ext.id] else { return webView }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? decoder.decode(WebExtensionManifest.self, from: $0) }

        if let page = parsed?.background?.page {
            webView.loadFileURL(folder.appendingPathComponent(page), allowingReadAccessTo: folder)
        } else {
            webView.loadHTMLString("<html><body></body></html>", baseURL: folder)
            for file in parsed?.backgroundScripts ?? [] {
                guard let source = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
                webView.evaluateJavaScript(source, in: nil, in: world, completionHandler: nil)
            }
        }
        Log.extensions.info("background context started for \(ext.name, privacy: .public)")
        return webView
    }

    private func teardownBackground(for id: UUID) {
        guard let webView = backgrounds.removeValue(forKey: id) else { return }
        webView.stopLoading()
        webView.removeFromSuperview()
        backgroundStates[id] = nil
    }

    // MARK: - Browser action popup

    /// Presents the extension's `default_popup` as a floating panel.
    func showPopup(for id: UUID) {
        if let existing = popups[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let ext = extensions.first(where: { $0.id == id }),
              ext.isEnabled,
              let folder = folderURLs[ext.id],
              let popupPath = ext.popupPath else {
            Log.extensions.info("extension popup unavailable")
            return
        }

        let world = contentWorld(for: "popup-" + ext.id.uuidString)
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.storageHandlerName)
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.runtimeHandlerName)
        controller.add(RegistryMessageHandler.shared, contentWorld: world, name: Self.runtimeReplyHandlerName)
        controller.addUserScript(WKUserScript(
            source: Self.chromeBridgeScript(extID: ext.id.uuidString, manifestJSON: ext.manifestJSON),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        webView.loadFileURL(folder.appendingPathComponent(popupPath), allowingReadAccessTo: folder)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = ext.name
        panel.contentView = webView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        popups[id] = panel
    }

    func closePopup(for id: UUID) {
        popups[id]?.close()
        popups[id] = nil
    }

    // MARK: - Runtime message routing (content/popup ⇄ background)

    /// Content/popup → background. Registers the response target, then
    /// delivers to the background's onMessage listeners.
    func handleRuntimeMessage(_ dict: [String: Any], originWebView: WKWebView, originWorld: WKContentWorld) {
        guard let extID = dict["ext"] as? String,
              dict["id"] != nil,
              let payload = dict["payload"],
              let ext = extensions.first(where: { $0.id.uuidString == extID }) else {
            // No background context — answer null so callbacks don't hang.
            let fallbackID = (dict["id"] as? NSNumber)?.intValue ?? 0
            originWebView.evaluateJavaScript(
                "window.__desireExtRespond && window.__desireExtRespond(\(fallbackID), null);",
                in: nil, in: originWorld, completionHandler: nil)
            return
        }
        let background = ensureBackground(for: ext)
        runtimeSeq += 1
        let responseID = runtimeSeq
        pendingResponses[responseID] = (originWebView, originWorld)

        let payloadJSON = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let extIDJSON = (try? JSONSerialization.data(withJSONObject: [ext.id.uuidString]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"?\""
        let js = "window.__desireExtRouteMessage && window.__desireExtRouteMessage(\(extIDJSON), \(payloadJSON), \(responseID));"
        background.evaluateJavaScript(js, in: nil, in: backgroundWorld(for: ext.id.uuidString), completionHandler: nil)
    }

    /// Background sendResponse → originating content/popup world.
    func handleRuntimeReply(_ dict: [String: Any]) {
        guard let id = (dict["id"] as? NSNumber)?.intValue,
              let target = pendingResponses.removeValue(forKey: id) else { return }
        let payloadJSON = (try? JSONSerialization.data(withJSONObject: dict["payload"] ?? NSNull()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let js = "window.__desireExtRespond && window.__desireExtRespond(\(id), \(payloadJSON));"
        target.webView.evaluateJavaScript(js, in: nil, in: target.world, completionHandler: nil)
    }

    func handleStorageMessage(_ dict: [String: Any], reply: @escaping (WKContentWorld, String) -> Void) {
        let op = dict["op"] as? String ?? ""
        guard let extID = dict["ext"] as? String,
              let id = (dict["id"] as? NSNumber)?.intValue else { return }
              _ = id
        _ = id
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

    // MARK: - Script message intake (registry-owned webviews)

    /// Handles messages from webviews the registry OWNS (background pages,
    /// popups). Content-script webviews are handled by WebView.swift's
    /// Coordinator, which routes into the same functions.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let webView = message.webView else { return }
        switch message.name {
        case Self.storageHandlerName:
            handleStorageMessage(dict) { world, js in
                webView.evaluateJavaScript(js, in: nil, in: world, completionHandler: nil)
            }
        case Self.runtimeHandlerName:
            handleRuntimeMessage(dict, originWebView: webView, originWorld: contentWorld(for: "popup"))
        case Self.runtimeReplyHandlerName:
            handleRuntimeReply(dict)
        default:
            break
        }
    }

    // MARK: - Storage backend (chrome.storage.local)

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
            cache = [:]
            await saveStorage(extID: extID, cache: cache)
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

    // MARK: - Names & helpers

    /// Per-extension content world (content scripts + popups).
    func contentWorld(for extID: String) -> WKContentWorld {
        if let world = worlds[extID] { return world }
        let world = WKContentWorld.world(name: "webext-" + extID)
        worlds[extID] = world
        return world
    }

    /// Separate world for the background context of an extension.
    private func backgroundWorld(for extID: String) -> WKContentWorld {
        contentWorld(for: "bg-" + extID)
    }

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Desire", isDirectory: true).appendingPathComponent("extensions", isDirectory: true)
    }

    // MARK: - Bridge scripts

    /// Content/popup world bridge: chrome.storage (native-backed),
    /// chrome.runtime.sendMessage (routed to the background context),
    /// chrome.runtime.onMessage listener registry.
    nonisolated static func chromeBridgeScript(extID: String, manifestJSON: String) -> String {
        var js = "(function(){"
        js += "if(window.__desireExtBridgeInstalled)return;"
        js += "window.__desireExtBridgeInstalled=true;"
        js += "const extID=" + String(reflecting: extID) + ";"
        js += "const handlers={};let cbSeq=0;"
        js += "function native(op,payload){return new Promise(function(resolve){"
        js += "cbSeq+=1;const cbId=cbSeq;handlers[cbId]=resolve;"
        js += "window.webkit.messageHandlers.webextStorage.postMessage({ext:extID,op:op,id:cbId,payload:payload===undefined?null:payload});});}"
        js += "window.__desireExtRespond=function(id,result){if(handlers[id]){handlers[id](result);delete handlers[id];}};"
        js += "const routeListeners=[];"
        js += "const runtime={id:extID,getManifest:function(){return " + manifestJSON + "},"
        js += "sendMessage:function(message,cb){cbSeq+=1;const cbId=cbSeq;if(cb)handlers[cbId]=cb;"
        js += "window.webkit.messageHandlers.webextRuntime.postMessage({ext:extID,id:cbId,payload:message===undefined?null:message});},"
        js += "onMessage:{addListener:function(fn){routeListeners.push(fn);}}};"
        js += "const local={"
        js += "get:function(keys,cb){native('get',keys===undefined?null:keys).then(function(r){if(cb)cb(r);});},"
        js += "set:function(items,cb){native('set',items).then(function(){if(cb)cb();});},"
        js += "remove:function(keys,cb){native('remove',keys).then(function(){if(cb)cb();});},"
        js += "clear:function(cb){native('clear',null).then(function(){if(cb)cb();});}};"
        js += "local.sync=local;"
        js += "window.chrome=window.chrome||{};window.chrome.runtime=runtime;window.chrome.storage={local:local,sync:local};"
        js += "})();"
        return js
    }

    /// Background world bridge: chrome.runtime.onMessage registry +
    /// sendResponse, routeMessage dispatcher, chrome.storage (native).
    nonisolated static func backgroundBridgeScript(extID: String) -> String {
        var js = "(function(){"
        js += "if(window.__desireBgBridgeInstalled)return;"
        js += "window.__desireBgBridgeInstalled=true;"
        js += "const listeners=[];let cbSeq=0;const handlers={};"
        js += "const EXTID=" + String(reflecting: extID) + ";"
        js += "function native(op,payload){return new Promise(function(resolve){"
        js += "cbSeq+=1;const cbId='bg'+cbSeq;handlers[cbId]=resolve;"
        js += "window.webkit.messageHandlers.webextStorage.postMessage({ext:EXTID,op:op,id:cbId,payload:payload===undefined?null:payload});});}"
        js += "window.chrome=window.chrome||{};"
        js += "chrome.runtime=chrome.runtime||{};"
        js += "chrome.runtime.getManifest=chrome.runtime.getManifest||function(){return{name:'background'}};"
        js += "chrome.runtime.onMessage={addListener:function(fn){listeners.push(fn);}};"
        js += "chrome.runtime.sendResponse=function(responseId,response){"
        js += "window.webkit.messageHandlers.webextRuntimeReply.postMessage({id:responseId,payload:response===undefined?null:response});};"
        js += "const local={"
        js += "get:function(keys,cb){native('get',keys===undefined?null:keys).then(function(r){if(cb)cb(r);});},"
        js += "set:function(items,cb){native('set',items).then(function(){if(cb)cb();});},"
        js += "remove:function(keys,cb){native('remove',keys).then(function(){if(cb)cb();});},"
        js += "clear:function(cb){native('clear',null).then(function(){if(cb)cb();});}};"
        js += "chrome.storage={local:local,sync:local};"
        js += "window.__desireExtRouteMessage=function(senderID,message,responseId){"
        js += "const sender={id:senderID};let responded=false;let async=false;let syncResult;let hasSync=false;"
        js += "for(const fn of listeners){"
        js += "const r=fn(message,sender,function(resp){"
        js += "if(responded)return;responded=true;"
        js += "window.webkit.messageHandlers.webextRuntimeReply.postMessage({id:responseId,payload:resp===undefined?null:resp});});"
        js += "if(r===true){async=true;}else if(r!==undefined&&!responded){syncResult=r;hasSync=true;}}"
        js += "if(!responded&&!async){responded=true;"
        js += "window.webkit.messageHandlers.webextRuntimeReply.postMessage({id:responseId,payload:null});}};"
        js += "})();"
        return js
    }
}

/// Delivers script messages from registry-owned webviews (background pages,
/// popups) into the registry.
@MainActor
final class RegistryMessageHandler: NSObject, WKScriptMessageHandler {
    static let shared = RegistryMessageHandler()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        WebExtensionRegistry.shared.userContentController(userContentController, didReceive: message)
    }
}
