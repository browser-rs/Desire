import AppKit
import Foundation
import WebKit

/// 窗口整理器（v0.8.52 批 3）：跨窗口的批量标签整理，Agent 工具与桥共用。
///
/// 四种模式：
/// - `mergeAll`：把所有其他用户窗口的标签并入源窗口（空窗口随即关闭）
/// - `dedupe`：跨窗 URL 去重（保留最先出现的一份，优先源窗口）
/// - `onlyHost`：源窗口里只保留指定 host 的标签，其余关闭
/// - `splitBySite`：源窗口按 host 拆成多组，第一组留在源窗口，其余每组开
///   一扇新窗口（需要 opener；没有 owner 会话时不可用）
///
/// 所有搬运都走 `TabWindowMove`（与拖拽同一路径，保留 history/挂起状态）。
@MainActor
enum WindowOrganizer {
    enum Mode: Equatable {
        case mergeAll
        case dedupe
        case onlyHost(String)
        case splitBySite
    }

    struct Failure: Error {
        let message: String
    }

    struct Summary {
        var moved = 0
        var closed = 0
        var windowsOpened = 0
        var detail: [String] = []
    }

    static func organize(mode: Mode,
                         source: TabManager,
                         opener: (() async -> TabManager?)? = nil,
                         progress: ((Int, Int) -> Void)? = nil) async -> Result<Summary, Failure> {
        let userWindows = TabSessionCoordinator.shared.liveManagers().filter {
            WindowRoleRegistry.shared.role(for: $0.sessionKey) == .user
        }
        switch mode {
        case .mergeAll:
            var summary = Summary()
            let others = userWindows.filter { $0 !== source }
            let total = others.reduce(0) { $0 + $1.tabs.count }
            var done = 0
            for manager in others {
                for tab in manager.tabs {
                    if TabWindowMove.move(tab, from: manager, to: source) {
                        summary.moved += 1
                    }
                    done += 1
                    progress?(done, max(1, total))
                    if done % 8 == 0 { await Task.yield() }
                }
            }
            summary.detail.append("merged \(summary.moved) tab(s) from \(others.count) window(s)")
            return .success(summary)

        case .dedupe:
            var summary = Summary()
            var seen = Set<String>()
            let ordered = [source] + userWindows.filter { $0 !== source }
            for manager in ordered {
                for tab in manager.tabs {
                    let url = normalizedURL(tab)
                    guard !url.isEmpty else { continue }
                    if seen.contains(url) {
                        if close(tab, in: manager) { summary.closed += 1 }
                    } else {
                        seen.insert(url)
                    }
                    if summary.closed % 8 == 0 { await Task.yield() }
                }
            }
            summary.detail.append("removed \(summary.closed) duplicate tab(s)")
            return .success(summary)

        case .onlyHost(let host):
            let target = host.lowercased()
            var summary = Summary()
            let total = source.tabs.count
            for (index, tab) in source.tabs.enumerated().reversed() {
                let tabHost = (tab.browser.webView.url ?? URL(string: tab.urlString))?.host?.lowercased() ?? ""
                if tabHost != target, close(tab, in: source) {
                    summary.closed += 1
                }
                progress?(total - index, total)
                if summary.closed % 8 == 0 { await Task.yield() }
            }
            summary.detail.append("kept \(source.tabs.count) tab(s) on \(host), closed \(summary.closed)")
            return .success(summary)

        case .splitBySite:
            guard let opener else {
                return .failure(Failure(message: "splitBySite needs an agent-bound window (no owner session to create windows)"))
            }
            var groups: [String: [Tab]] = [:]
            var order: [String] = []
            for tab in source.tabs {
                let host = (tab.browser.webView.url ?? URL(string: tab.urlString))?.host?.lowercased()
                    ?? ""
                if groups[host] == nil { order.append(host) }
                groups[host, default: []].append(tab)
            }
            guard order.count > 1 else {
                return .success(Summary(detail: ["all tabs already share one site — nothing to split"]))
            }
            var summary = Summary()
            // 第一组留在源窗口，其余每组开一扇新窗口。
            for (groupIndex, host) in order.enumerated().dropFirst() {
                let tabs = groups[host] ?? []
                guard let fresh = await opener() else {
                    summary.detail.append("could not open a window for \(host) — stopped after \(groupIndex) group(s)")
                    return .success(summary)
                }
                summary.windowsOpened += 1
                for tab in tabs {
                    if TabWindowMove.move(tab, from: source, to: fresh) {
                        summary.moved += 1
                    }
                }
                summary.detail.append("\(host): \(tabs.count) tab(s) → new window")
            }
            return .success(summary)
        }
    }

    private static func normalizedURL(_ tab: Tab) -> String {
        let raw = tab.browser.webView.url?.absoluteString ?? tab.urlString
        guard raw.hasPrefix("http") else { return "" }
        return raw
    }

    private static func close(_ tab: Tab, in manager: TabManager) -> Bool {
        guard manager.tabs.count > 1,
              let index = manager.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        manager.closeTab(at: index)
        return true
    }
}
