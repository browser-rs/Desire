import SwiftUI

/// 独立 Agent 窗口右栏的目的地：侧栏"智能体"区切换；会话点击/返回按钮
/// 都回到聊天列。
enum AgentWindowDestination: Hashable {
    case chat
    case tasks
    case skills
    case memory
    case stats
    case trace
    case capabilities
    case doctor
}

/// 独立 Agent 窗口的**两栏布局根视图**（2026-10-10）：左栏 = 智能体侧栏
/// （目的地导航 + 会话列表，`AgentWindowSidebar`），右栏 = 目的地对应的
/// 页面（默认聊天 `AgentPanel`）。侧栏**默认折叠**，显隐状态落 UserDefaults。
/// 分栏走 HSplitView 原生分隔条（项目既定方案），宽度协商只在子视图
/// minWidth/idealWidth/maxWidth 上做。浏览器内嵌的 Agent 侧栏面板是窄列，
/// **不走这里**——保持单栏（用户明确：嵌入的那块不变）。
struct AgentWindowRoot: View {
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var conversationStore: ConversationStore
    var onToggleWhiteboard: (() -> Void)? = nil
    var onToggleBall: (() -> Void)? = nil
    /// 侧栏展开/收起后回调（宿主借此调整窗口 minSize、放宽过窄的窗口）。
    var onSidebarVisibilityChanged: ((Bool) -> Void)? = nil

    @State private var isSidebarExpanded = UserDefaults.standard.bool(forKey: AgentWindowRoot.sidebarKey)
    @State private var destination: AgentWindowDestination = .chat

    /// `bool(forKey:)` 对不存在的键返回 false = 默认折叠。
    static let sidebarKey = "agent.window.sidebarExpanded"

    var body: some View {
        HSplitView {
            if isSidebarExpanded {
                AgentWindowSidebar(
                    destination: $destination,
                    conversationStore: conversationStore,
                    sessionStore: store,
                    onNewChat: {
                        switchDestination(.chat)
                        store.clear()
                    },
                    onActivateChat: { switchDestination(.chat) }
                )
                .frame(minWidth: 190, idealWidth: 232, maxWidth: 340)
                .frame(maxHeight: .infinity)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 右栏目的地：聊天之外复用既有子页（记忆/统计/轨迹/能力），任务与
    /// 技能是本次新增的独立页。返回按钮统一回聊天。
    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .chat:
            AgentPanel(
                store: store,
                conversationStore: conversationStore,
                onToggleWhiteboard: onToggleWhiteboard,
                onToggleBall: onToggleBall,
                onToggleSidebar: { setSidebarExpanded(!isSidebarExpanded) },
                isSidebarExpanded: isSidebarExpanded,
                hidesHeaderNavigation: true
            )
        case .tasks:
            AgentTasksView(onBack: { switchDestination(.chat) })
        case .skills:
            AgentSkillsView(
                onBack: { switchDestination(.chat) },
                onUseSkill: { name in
                    // 从技能页直接发起：切回聊天列并把使用指令发给 Agent。
                    switchDestination(.chat)
                    store.sendMessage(String(localized: "Use the \(name) skill"))
                }
            )
        case .memory:
            AgentMemoryView(onBack: { switchDestination(.chat) })
        case .stats:
            AgentStatsView(conversationStore: conversationStore, preference: store.preference,
                           onBack: { switchDestination(.chat) })
        case .trace:
            AgentTraceView(conversationStore: conversationStore, preference: store.preference,
                           onBack: { switchDestination(.chat) })
        case .capabilities:
            AgentCapabilitiesView(onBack: { switchDestination(.chat) })
        case .doctor:
            AgentDoctorView(onBack: { switchDestination(.chat) })
        }
    }

    private func switchDestination(_ target: AgentWindowDestination) {
        guard target != destination else { return }
        withAnimation(.transitionNormal) {
            destination = target
        }
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
