import Combine
import Foundation
import WebKit
import os

/// One network-interception rule: block or redirect. Backed by
/// WKContentRuleList (WebKit's declarative interception) — rules apply to
/// every registered webview right after compilation.
///
/// v1 deliberately ships only block/redirect: WebKit's declarative rules
/// cannot serve canned response BODIES (that needs a Service Worker /
/// proxy layer — future work). Redirect supports URL rewriting.
struct InterceptRule: Codable, Identifiable {
    let id: UUID
    /// URL filter the rule triggers on (WebKit url-filter syntax; substring
    /// match, `*` wildcards allowed).
    var urlFilter: String
    var kind: Kind
    /// Redirect target URL (redirect kind only).
    var payload: String?
    var isEnabled: Bool = true
    var createdAt = Date()

    enum Kind: String, Codable {
        case block
        case redirect
    }

    // MARK: - URL filter 构造（面板/桥共用）

    /// WebKit 的 `url-filter` 是**正则**：URL 里的 `.` `?` `*` `+` `(` 等必须
    /// 转义，否则 `?` 会让规则编译失败、`*` 会变成通配符（把别的 URL 一起拦掉）。
    static func escapedForURLFilter(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.|?*+()[]{}".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// 只匹配这一个 URL（面板"Block This URL"）。
    static func exactFilter(for url: String) -> String {
        "^\(escapedForURLFilter(url))$"
    }

    /// 匹配整个主机（面板"Block This Host"）：`^https?://host(/|$|:)`。
    static func hostFilter(for url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return "^[a-z]+://\(escapedForURLFilter(host))(/|$|:)"
    }
}

/// Store + compiler + distributor for interception rules (0.1.13). Rules
/// are app-wide (not per-tab) in v1.
@MainActor
final class InterceptStore: ObservableObject {
    static let shared = InterceptStore()

    @Published private(set) var rules: [InterceptRule] = []

    private var compiled: [String: WKContentRuleList] = [:]
    private struct WeakController { weak var controller: WKUserContentController? }
    private var registered: [WeakController] = []
    private var addedPerController: [ObjectIdentifier: [(ruleID: UUID, list: WKContentRuleList)]] = [:]

    private static let storageKey = "intercept-rules"
    private static let log = Log.agent

    private init() {
        rules = DiskStore.load([InterceptRule].self, key: Self.storageKey) ?? []
        for rule in rules where rule.isEnabled {
            compileAndDistribute(rule)
        }
    }

    // MARK: - Management

    @discardableResult
    func add(urlFilter: String, kind: InterceptRule.Kind, payload: String?) -> InterceptRule? {
        let trimmed = urlFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if kind == .redirect && (payload ?? "").isEmpty { return nil }
        let rule = InterceptRule(id: UUID(), urlFilter: trimmed, kind: kind, payload: payload)
        rules.append(rule)
        save()
        compileAndDistribute(rule)
        return rule
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
        removeEverywhere(ruleID: id)
    }

    func clear() {
        let ids = rules.map(\.id)
        rules.removeAll()
        save()
        ids.forEach { removeEverywhere(ruleID: $0) }
    }

    private func save() {
        DiskStore.save(rules, key: Self.storageKey)
    }

    // MARK: - WebKit distribution

    /// Registers a webview's content controller and applies every existing
    /// rule to it. Call from BrowserState init (config-level controller).
    func apply(to controller: WKUserContentController) {
        registered.removeAll { $0.controller == nil }
        guard !registered.contains(where: { $0.controller === controller }) else { return }
        registered.append(WeakController(controller: controller))
        for rule in rules where rule.isEnabled {
            if let list = compiled[compileKey(rule)] {
                controller.add(list)
                addedPerController[ObjectIdentifier(controller), default: []].append((rule.id, list))
            }
        }
    }

    private func compileKey(_ rule: InterceptRule) -> String {
        "intercept-\(rule.id.uuidString)"
    }

    private func compileAndDistribute(_ rule: InterceptRule) {
        let source = Self.webkitRuleJSON(for: rule)
        guard let store = WKContentRuleListStore.default() else { return }
        let key = compileKey(rule)
        store.compileContentRuleList(forIdentifier: key, encodedContentRuleList: source) { [weak self] list, error in
            guard let self, let list else {
                Self.log.error("intercept: compile failed for \(rule.urlFilter, privacy: .public): \(error?.localizedDescription ?? "?", privacy: .public)")
                return
            }
            Task { @MainActor in
                self.compiled[key] = list
                self.addEverywhere(list: list, ruleID: rule.id)
                Self.log.info("intercept: rule live (\(rule.kind.rawValue, privacy: .public) \(rule.urlFilter, privacy: .public))")
            }
        }
    }

    private func addEverywhere(list: WKContentRuleList, ruleID: UUID) {
        removeEverywhere(ruleID: ruleID)
        for box in registered {
            guard let controller = box.controller else { continue }
            controller.add(list)
            addedPerController[ObjectIdentifier(controller), default: []].append((ruleID, list))
        }
    }

    private func removeEverywhere(ruleID: UUID) {
        for box in registered {
            guard let controller = box.controller else { continue }
            let key = ObjectIdentifier(controller)
            guard var added = addedPerController[key] else { continue }
            let matched = added.filter { $0.ruleID == ruleID }
            added.removeAll { $0.ruleID == ruleID }
            addedPerController[key] = added
            for entry in matched { controller.remove(entry.list) }
        }
    }

    /// Encodes one rule as WebKit content-rule JSON.
    static func webkitRuleJSON(for rule: InterceptRule) -> String {
        let action: [String: Any]
        switch rule.kind {
        case .block:
            action = ["type": "block"]
        case .redirect:
            action = ["type": "redirect", "redirect": ["url": rule.payload ?? ""]]
        }
        let ruleObject: [String: Any] = [
            "id": rule.id.uuidString,
            "priority": 10,
            "action": action,
            "trigger": ["url-filter": rule.urlFilter],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: [ruleObject])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
