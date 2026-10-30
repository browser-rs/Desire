import Foundation

/// 窗口目标的**单点解析**（v0.8.24）：所有"该操作哪扇窗"的代码走这里，
/// 不再各自猜 `activeTabManager`。
@MainActor
enum WindowTargetResolver {
    /// Agent 自己的浏览窗口（混合模式）。
    static func agentManager() -> TabManager? {
        TabSessionCoordinator.shared.liveManagers().first {
            WindowRoleRegistry.shared.role(for: $0.sessionKey) == .agent
        }
    }

    /// 专注模式的内嵌面板（按需创建）。
    static func paneManager() -> TabManager {
        AgentPaneManager.shared.ensure()
    }

    /// 当前用户可操作窗口（活动窗口）。
    static func userManager() -> TabManager? {
        TabSessionCoordinator.shared.activeTabManager
    }

    /// 按模式给出"Agent 默认操作面"。
    static func surfaceManager(for mode: AppUsageMode) -> TabManager? {
        switch mode {
        case .agentFocus:
            return paneManager()
        case .hybrid:
            return agentManager() ?? userManager()
        case .browser:
            return userManager()
        }
    }
}
