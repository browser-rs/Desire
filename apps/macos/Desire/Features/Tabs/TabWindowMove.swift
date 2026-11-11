import AppKit
import Foundation

/// 标签跨窗口移动 / 窗口聚焦（v0.8.52 批 3）：Agent 工具与桥共用同一实现，
/// 避免"菜单路径"和"工具路径"各写一套。移动走与拖拽完全相同的语义：
/// 先从组里摘除 → moveOut → 目标 absorb/insert（保留 history 与挂起状态）。
@MainActor
enum TabWindowMove {
    /// 把标签从 source 移到 target。index = 目标落点（nil = 追加并选中）。
    @discardableResult
    static func move(_ tab: Tab, from source: TabManager, to target: TabManager,
                     index: Int? = nil) -> Bool {
        guard source !== target else { return false }
        AppState.live?.tabGroupStore.removeTabFromAll(tab.id)
        source.moveOut(tab)
        if let index {
            let clamped = min(max(0, index), target.tabs.count)
            target.insert(tab, at: clamped)
            target.selectTab(at: clamped)
        } else {
            target.absorb(tab)
            target.selectTab(at: target.tabs.count - 1)
        }
        focus(target)
        if source.tabs.isEmpty {
            (WindowSurfaceRegistry.shared.window(for: source.sessionKey)
                ?? tab.browser.webView.window)?.close()
        }
        return true
    }

    /// 激活窗口并把它设为活动 manager。
    static func focus(_ manager: TabManager) {
        let window = WindowSurfaceRegistry.shared.window(for: manager.sessionKey)
            ?? manager.selectedTab?.browser.webView.window
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        TabSessionCoordinator.shared.setActive(manager)
    }

    /// 解析窗口标识：`session-<uuid>` / uuid 前缀 / agent 会话短 id。
    static func resolve(_ raw: String?) -> TabManager? {
        guard let raw, !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        for manager in TabSessionCoordinator.shared.liveManagers() {
            guard let key = manager.sessionKey else { continue }
            if key.lowercased() == lowered
                || key.lowercased().hasPrefix("session-" + lowered) {
                return manager
            }
        }
        // Agent 会话短 id（与既有 window 参数语义兼容）
        if let entry = AgentScheduler.shared.liveSessions()
            .first(where: { $0.id.uuidString.lowercased().hasPrefix(lowered) }),
           let manager = entry.store?.boundTabManager {
            return manager
        }
        return nil
    }

    /// 窗口的短标识（8 位 UUID）与展示标题（供 listWindows / 工具回包）。
    static func identifier(_ manager: TabManager) -> String {
        guard let key = manager.sessionKey,
              let id = TabSessionCoordinator.shared.sessionID(forKey: key) else { return "?" }
        return String(id.uuidString.prefix(8))
    }

    static func displayTitle(_ manager: TabManager) -> String {
        let window = WindowSurfaceRegistry.shared.window(for: manager.sessionKey)
        let title = window?.title ?? manager.selectedTab?.displayTitle ?? ""
        return title.isEmpty ? "\(manager.tabs.count) tabs" : title
    }
}
