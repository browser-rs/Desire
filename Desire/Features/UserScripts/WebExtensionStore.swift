import Foundation
import os
import WebKit
@preconcurrency import UserNotifications

/// WebExtension `storage.local` backend. 0.3.3: per-plugin namespaces —
/// the host sets `__desireExtID` before evaluating each plugin and the
/// RPC carries it; storage then lives under `desire.webext.storage.<id>`.
/// `nil` ext = legacy shared bucket (v0.2.13 data stays readable there).
@MainActor
enum WebExtensionStore {
    private static let legacyKey = "desire.webext.storage"

    /// Chrome semantics: null/omitted → all items; string or array →
    /// subset (missing keys come back as null).
    static func get(keys: Any?, ext: String?) -> [String: Any] {
        let store = loadAll(ext: ext)
        switch keys {
        case nil:
            return store
        case let s as String:
            return [s: store[s] ?? NSNull()]
        case let arr as [Any]:
            let names = arr.compactMap { $0 as? String }
            return Dictionary(uniqueKeysWithValues: names.map { ($0, store[$0] ?? NSNull()) })
        default:
            return store
        }
    }

    static func set(items: [String: Any], ext: String?) {
        var store = loadAll(ext: ext)
        for (key, value) in items where JSONSerialization.isValidJSONObject([value]) {
            store[key] = value
        }
        saveAll(store, ext: ext)
    }

    static func remove(keys: [String], ext: String?) {
        var store = loadAll(ext: ext)
        for key in keys { store.removeValue(forKey: key) }
        saveAll(store, ext: ext)
    }

    static func clear(ext: String?) {
        saveAll([:], ext: ext)
    }

    /// 一key一桶：nil = legacy 共享桶；有插件身份 = 独立命名空间。
    private static func key(for ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return legacyKey }
        return "\(legacyKey).\(ext)"
    }

    private static func loadAll(ext: String?) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: key(for: ext)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func saveAll(_ store: [String: Any], ext: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: store) else { return }
        UserDefaults.standard.set(data, forKey: key(for: ext))
    }

    /// `notifications.create` — TCC authorization is requested lazily on
    /// first use (downloads precedent; prompting at init gets the process
    /// killed under non-standard launch contexts).
    static func createNotification(_ options: [String: Any], completion: @escaping @MainActor (Any?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                Task { @MainActor in completion(nil) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? "Desire"
            content.body = options["message"] as? String ?? ""
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                let result: Any? = error == nil ? ["id": request.identifier] : nil
                Task { @MainActor in completion(result) }
            }
        }
    }
}

/// Fans tab lifecycle events out to extension-world listeners. Direct
/// calls from TabManager (BridgeEventBus only publishes when an SSE
/// client is connected — extensions must hear events regardless).
/// Listeners are keyed by BrowserState identity; weak, pruned on fire.
@MainActor
final class ExtensionEventHub {
    static let shared = ExtensionEventHub()

    private struct WeakBox { weak var state: BrowserState? }
    private var listeners: [ObjectIdentifier: WeakBox] = [:]

    private init() {}

    func register(_ state: BrowserState) {
        listeners[ObjectIdentifier(state)] = WeakBox(state: state)
    }

    func unregister(_ state: BrowserState) {
        listeners.removeValue(forKey: ObjectIdentifier(state))
    }

    /// 诊断：注册表大小 + 各页监听标志。
    func debugInfo() -> [String: Any] {
        let flags = listeners.values.compactMap { box -> Bool? in box.state.map { $0.hasExtensionTabListeners } }
        return ["registered": listeners.count, "listening": flags.filter { $0 }.count]
    }

    func fire(_ event: String, tabID: UUID, extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["tabId": tabID.uuidString]
        for (k, v) in extra { payload[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__desireExt && window.__desireExt._fire('\(event)', \(json))"
        var delivered = 0
        for box in listeners.values {
            guard let state = box.state, state.hasExtensionTabListeners else { continue }
            delivered += 1
            state.webView.evaluateJavaScript(js, in: nil, in: WebView.extensionWorld) { result in
                if case .failure(let error) = result {
                    Log.userScripts.error("webext fire JS failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        Log.userScripts.info("webext: fire \(event, privacy: .public) registered=\(self.listeners.count) delivered=\(delivered)")
    }
}
