import Combine
import Foundation
import WebKit
import os

/// 一键按站点整理当前窗口的未分组标签（v0.8.0，AI 标签整理的第一档：
/// 本地确定性规则；模型细分留作后续）。
@MainActor
final class TabOrganizer: ObservableObject {
    static let shared = TabOrganizer()

    @Published private(set) var canUndo = false
    /// 模型细分（v0.8.1）：正在等待/解析模型结果。
    @Published private(set) var isOrganizing = false
    /// 最近一次 AI 整理失败的原因（成功时清空）。UI 用 alert 展示。
    @Published private(set) var lastError: String?
    private var snapshot: [TabGroup]?

    private init() {}

    @discardableResult
    func organize(tabs: [Tab], store: TabGroupStore) -> Int {
        var candidates: [(id: UUID, host: String)] = []
        for tab in tabs {
            guard !tab.isOnNewTabPage, !tab.isIncognito,
                  store.group(for: tab.id) == nil else { continue }
            let host = tab.browser.webView.url?.host
                ?? URL(string: tab.urlString)?.host
                ?? ""
            if !host.isEmpty {
                candidates.append((tab.id, host))
            }
        }
        let plan = TabOrganizePlan.groups(for: candidates)
        guard !plan.isEmpty else {
            canUndo = false
            snapshot = nil
            return 0
        }
        snapshot = store.snapshot()
        for group in plan {
            let created = store.create(
                name: group.host,
                colorIndex: TabOrganizePlan.colorIndex(for: group.host))
            for id in group.tabIDs {
                store.addTab(id, to: created.id)
            }
        }
        canUndo = true
        return plan.count
    }

    func undo(store: TabGroupStore) {
        guard let snapshot else { return }
        store.replaceAll(snapshot)
        self.snapshot = nil
        canUndo = false
    }

    /// 按**主题**整理（v0.8.1，模型细分）：把未分组标签的标题/站点/URL 交给
    /// 当前模型分组，严格校验返回的下标后再建组。调用一次模型产生少量 token，
    /// 由用户从菜单显式触发；失败返回 0 并把原因写进 `lastError`。
    @discardableResult
    func organizeByTopic(tabs: [Tab], store: TabGroupStore,
                         preference: AgentPreferenceStore?) async -> Int {
        lastError = nil
        guard let preference else {
            lastError = String(localized: "No AI service is configured — add one in Settings → AI.")
            return 0
        }
        var candidates: [Tab] = []
        for tab in tabs {
            guard !tab.isOnNewTabPage, !tab.isIncognito,
                  store.group(for: tab.id) == nil else { continue }
            candidates.append(tab)
            if candidates.count >= 40 { break }
        }
        guard candidates.count >= 2 else {
            lastError = String(localized: "Not enough ungrouped tabs to organize by topic.")
            return 0
        }
        let rows: [[String: Any]] = candidates.enumerated().map { index, tab in
            let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
            return ["i": index,
                    "title": String(tab.displayTitle.prefix(120)),
                    "host": tab.browser.webView.url?.host ?? URL(string: url)?.host ?? "",
                    "url": String(url.prefix(200))]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let payload = String(data: data, encoding: .utf8) else {
            lastError = String(localized: "Could not prepare the tab list.")
            return 0
        }
        isOrganizing = true
        defer { isOrganizing = false }
        let text = await MemoryExtractor.collectText(
            preference: preference,
            system: """
            You group browser tabs by topic. Input is a JSON array of tabs with index i, title, host and url.
            Return ONLY a JSON array: [{"name":"short topic","tabs":[0,2]}].
            Rules: at most 8 groups; every group needs at least 2 tabs; omit singletons; use the user's language for names; never invent indices; do not reuse an index.
            """,
            user: payload)
        let ids = candidates.map(\.id)
        let groups = TabTopicPlan.parse(text, tabIDs: ids)
        guard !groups.isEmpty else {
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = preview.isEmpty
                ? String(localized: "The AI returned no grouping plan.")
                : String(localized: "The AI's grouping plan couldn't be used — try again.")
            Log.agent.info("tab topic organize: no usable groups from model reply (\(preview.count) chars)")
            return 0
        }
        snapshot = store.snapshot()
        for group in groups {
            let created = store.create(name: group.name,
                                       colorIndex: TabTopicPlan.colorIndex(for: group.name))
            for id in group.tabIDs {
                store.addTab(id, to: created.id)
            }
        }
        canUndo = true
        return groups.count
    }
}
