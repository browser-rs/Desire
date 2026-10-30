import AppKit
import Foundation
import os

/// 模式切换的**编排**（v0.8.23）：只做"切模式时该建/该指向什么"，
/// 界面分支由 ContentView 观察 `AppModeStore` 自动跟随。
@MainActor
enum AppModeCoordinator {
    static func apply(_ mode: AppUsageMode) {
        AppModeStore.shared.setMode(mode)
        switch mode {
        case .browser:
            break
        case .agentFocus:
            _ = AgentPaneManager.shared.ensure()
        case .hybrid:
            ensureAgentWindow()
        }
    }

    /// 并排（v0.8.24）：把用户窗口与 Agent 窗口平铺左右。只调 frame，
    /// 不做应用内分屏——两窗各自保留标签/焦点，互不干扰。
    static func arrangeSideBySide() {
        guard let user = WindowTargetResolver.userManager(),
              let agent = WindowTargetResolver.agentManager(),
              let userWindow = WindowSurfaceRegistry.shared.window(for: user.sessionKey),
              let agentWindow = WindowSurfaceRegistry.shared.window(for: agent.sessionKey),
              let screen = userWindow.screen ?? NSScreen.main else { return }
        guard userWindow !== agentWindow else { return }
        let frame = screen.visibleFrame
        let half = frame.width / 2
        userWindow.setFrame(NSRect(x: frame.minX, y: frame.minY, width: half, height: frame.height),
                            display: true)
        agentWindow.setFrame(NSRect(x: frame.minX + half, y: frame.minY, width: half, height: frame.height),
                             display: true)
        userWindow.makeKeyAndOrderFront(nil)
    }

    /// 混合模式：没有 Agent 角色的窗口就开一扇。建窗由现有的
    /// "请求新窗口"通知完成（用户动作触发，允许它成为 key），角色由
    /// `WindowRoleRegistry.pendingRole` 带给 SessionRestore。
    static func ensureAgentWindow() {
        guard WindowTargetResolver.agentManager() == nil else { return }
        WindowRoleRegistry.shared.pendingRole = .agent
        // 通知带会话点名：窗口侧只让"持有该会话的窗口"开新窗（既有约定）。
        var info: [String: Any] = [:]
        if let target = AgentScheduler.shared.deliveryTarget,
           let entry = AgentScheduler.shared.liveSessions().first(where: { $0.store === target }) {
            info["session"] = entry.id.uuidString
        }
        NotificationCenter.default.post(name: .desireOpenNewWindow, object: nil,
                                        userInfo: info.isEmpty ? nil : info)
        // 没人接（应用在后台/无窗口）时别把角色留成"下一次开窗就变 Agent 窗"。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if WindowRoleRegistry.shared.pendingRole == .agent {
                WindowRoleRegistry.shared.pendingRole = nil
                Log.agent.info("hybrid: no window handled the agent-window request; pending role cleared")
            }
        }
    }
}
