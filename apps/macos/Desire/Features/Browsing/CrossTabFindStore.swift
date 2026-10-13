import Combine
import Foundation
import WebKit

/// 跨标签查找（0.7.14 查找增强）：Find bar 扫描其他标签页的匹配计数，
/// 结果列出（标签名 + 计数），点击跳到该标签并执行查找。
/// 计数用 WebView.findCountJS 同款 TreeWalker（纯读，无高亮副作用）。
@MainActor
final class CrossTabFindStore: ObservableObject {
    static let shared = CrossTabFindStore()

    struct Match: Identifiable, Equatable {
        let tabID: UUID
        let title: String
        let url: String
        let count: Int

        var id: String { tabID.uuidString }
    }

    /// 其他标签页中的匹配（按计数降序）。当前标签不在列表（Find bar 本身服务它）。
    @Published private(set) var matches: [Match] = []
    @Published private(set) var isScanning = false
    /// 本次扫描的查询词（面板据其判断是否过期）。
    private(set) var query: String = ""

    func scan(query: String, excluding tabID: UUID?) {
        self.query = query
        matches = []
        guard !query.isEmpty else { return }
        isScanning = true
        let js = Self.countJS(query: query)
        Task { [weak self] in
            var found: [Match] = []
            let managers = TabSessionCoordinator.shared.liveManagers()
            for manager in managers {
                for tab in manager.tabs where tab.id != tabID {
                    let count = try? await tab.browser.webView.evaluateJavaScript(js) as? Int
                    if let c = count, c > 0 {
                        found.append(Match(
                            tabID: tab.id,
                            title: tab.displayTitle,
                            url: tab.browser.webView.url?.absoluteString ?? tab.urlString,
                            count: c))
                    }
                }
            }
            found.sort { $0.count > $1.count }
            await MainActor.run { [weak self] in
                guard let self, self.query == query else { return }   // 查询已变 → 丢弃
                self.matches = found
                self.isScanning = false
            }
        }
    }

    /// 跳到匹配标签并执行查找（面板点击行为）。
    func openAndFind(tabID: UUID, query: String) {
        for manager in TabSessionCoordinator.shared.liveManagers() {
            guard let idx = manager.tabs.firstIndex(where: { $0.id == tabID }) else { continue }
            manager.selectTab(at: idx)
            // selectTab 后 webview 需要一帧成为 first responder 再 find。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                _ = try? await manager.tabs.first(where: { $0.id == tabID })?
                    .browser.webView.evaluateJavaScript(
                        CrossTabFindStore.countJS(query: query))
            }
            return
        }
    }

    /// TreeWalker 文本计数（与 WebView.findCountJS 同一实现——跨标签用无状态版本）。
    static func countJS(query: String) -> String {
        """
        (function() {
            var t = \(JSString.literal(query));
            if (!t) return 0;
            var r = new RegExp(t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
            var c = 0, walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            while (walk.nextNode()) { c += (walk.currentNode.nodeValue.match(r) || []).length; }
            return c;
        })()
        """
    }
}
