import SwiftUI

/// 独立 Agent 窗口的**两栏布局根视图**（2026-10-10）：左栏 = 会话列表侧栏
/// （`AgentWindowSidebar`），右栏 = 既有 `AgentPanel`。侧栏**默认折叠**，
/// 显隐状态落 UserDefaults（跨启动记住）。分栏走 HSplitView 原生分隔条
/// （项目既定方案），宽度协商只在子视图 minWidth/idealWidth/maxWidth 上做。
/// 浏览器内嵌的 Agent 侧栏面板是窄列，**不走这里**——保持单栏（用户明确：
/// 嵌入的那块不变）。
struct AgentWindowRoot: View {
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var conversationStore: ConversationStore
    var onToggleWhiteboard: (() -> Void)? = nil
    var onToggleBall: (() -> Void)? = nil
    /// 侧栏展开/收起后回调（宿主借此调整窗口 minSize、放宽过窄的窗口）。
    var onSidebarVisibilityChanged: ((Bool) -> Void)? = nil

    @State private var isSidebarExpanded = UserDefaults.standard.bool(forKey: AgentWindowRoot.sidebarKey)

    /// `bool(forKey:)` 对不存在的键返回 false = 默认折叠。
    static let sidebarKey = "agent.window.sidebarExpanded"

    var body: some View {
        HSplitView {
            if isSidebarExpanded {
                AgentWindowSidebar(
                    conversationStore: conversationStore,
                    sessionStore: store,
                    onNewChat: { store.clear() }
                )
                .frame(minWidth: 190, idealWidth: 232, maxWidth: 340)
                .frame(maxHeight: .infinity)
            }
            AgentPanel(
                store: store,
                conversationStore: conversationStore,
                onToggleWhiteboard: onToggleWhiteboard,
                onToggleBall: onToggleBall,
                onToggleSidebar: { setSidebarExpanded(!isSidebarExpanded) },
                isSidebarExpanded: isSidebarExpanded
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setSidebarExpanded(_ expanded: Bool) {
        guard expanded != isSidebarExpanded else { return }
        withAnimation(.transitionNormal) {
            isSidebarExpanded = expanded
        }
        UserDefaults.standard.set(expanded, forKey: Self.sidebarKey)
        onSidebarVisibilityChanged?(expanded)
    }
}
