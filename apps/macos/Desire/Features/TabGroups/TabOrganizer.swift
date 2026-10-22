import Combine
import Foundation
import WebKit

/// 一键按站点整理当前窗口的未分组标签（v0.8.0，AI 标签整理的第一档：
/// 本地确定性规则；模型细分留作后续）。
@MainActor
final class TabOrganizer: ObservableObject {
    static let shared = TabOrganizer()

    @Published private(set) var canUndo = false
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
}
