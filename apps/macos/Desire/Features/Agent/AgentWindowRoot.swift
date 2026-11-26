import SwiftUI

/// 独立 Agent 窗口右栏的目的地：侧栏"智能体"区切换；会话点击/返回按钮
/// 都回到聊天列。
enum AgentWindowDestination: Hashable {
    case chat
    case inbox
    case tasks
    case skills
    case memory
    case stats
    case trace
    case capabilities
    case doctor
    case promotion
    case excerpts
}

/// 独立 Agent 窗口的**两栏布局根视图**（2026-10-10）：左栏 = 智能体侧栏
/// （目的地导航 + 会话列表，`AgentWindowSidebar`），右栏 = 目的地对应的
/// 页面（默认聊天 `AgentPanel`）。侧栏**默认折叠**，显隐状态落 UserDefaults。
/// 分栏容器 = `NavigationSplitView`（v0.8.67 用户反馈：与设置页同款系统侧栏
/// ——毛玻璃列、系统分隔条可拖；此前是自定义 HSplitView）。开合交互不变：
/// detail 顶部 `sidebar.left` 按钮仍走 setSidebarExpanded（映射 columnVisibility
/// + 持久化 + 宿主 minSize 回调）。浏览器内嵌的 Agent 侧栏面板是窄列，
/// **不走这里**——保持单栏（用户明确：嵌入的那块不变）。
struct AgentWindowRoot: View {
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var conversationStore: ConversationStore
    var onToggleWhiteboard: (() -> Void)? = nil
    var onToggleBall: (() -> Void)? = nil
    /// 侧栏展开/收起后回调（宿主借此调整窗口 minSize、放宽过窄的窗口）。
    var onSidebarVisibilityChanged: ((Bool) -> Void)? = nil

    @State private var isSidebarExpanded = AppPrefs.defaults.bool(forKey: AgentWindowRoot.sidebarKey)
    @State private var destination: AgentWindowDestination = .chat

    /// `bool(forKey:)` 对不存在的键返回 false = 默认折叠。
    static let sidebarKey = "agent.window.sidebarExpanded"

    /// 与 isSidebarExpanded 双向映射（NavigationSplitView 的显隐枚举）。
    @State private var columnVisibility: NavigationSplitViewVisibility =
        AppPrefs.defaults.bool(forKey: AgentWindowRoot.sidebarKey) ? .all : .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
            .frame(maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 190, ideal: 232, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        // 用户点系统列边/列宽变化不会改 visibility；只有显式开合才会，
        // 这里回写权威状态（持久化 + 宿主 minSize 回调）。
        .onChange(of: columnVisibility) { _, newValue in
            setSidebarExpanded(newValue != .detailOnly)
        }
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
                hidesHeaderNavigation: true,
                promptCenter: store.promptCenter,
                // 独立窗口放开限宽（v0.8.67 用户反馈）：窗口可拖到很宽，
                // 固定 960 会在两侧留大空白。内嵌面板维持默认 960。
                contentMaxWidth: nil
            )
        case .inbox:
            AgentInboxView(
                conversationStore: conversationStore,
                onBack: { switchDestination(.chat) },
                onOpenConversation: { id in
                    switchDestination(.chat)
                    if let id { store.loadConversation(id) }
                },
                onOpenOperations: { switchDestination(.promotion) },
                onOpenTasks: { switchDestination(.tasks) },
                onSendToAgent: { [weak store] text in
                    switchDestination(.chat)
                    store?.sendMessage(text)
                }
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
        case .excerpts:
            ExcerptsPanel()
        case .promotion:
            PromotionView(
                onBack: { switchDestination(.chat) },
                onSendToAgent: { [weak store] text in
                    // 面板点按 → 切回聊天列并把指令发给 Agent（与技能页同款路径）。
                    switchDestination(.chat)
                    store?.sendMessage(text)
                })
        }
    }

    private func switchDestination(_ target: AgentWindowDestination) {
        guard target != destination else { return }
        withAnimation(.transitionNormal) {
            destination = target
        }
    }

    private func setSidebarExpanded(_ expanded: Bool) {
        guard isSidebarExpanded != expanded else { return }
        withAnimation(.transitionNormal) {
            isSidebarExpanded = expanded
            // columnVisibility 的 onChange 会再进一次 setSidebarExpanded，
            // 此时 isSidebarExpanded 已同步、guard 直接返回——无递归。
            columnVisibility = expanded ? .all : .detailOnly
        }
        AppPrefs.defaults.set(expanded, forKey: Self.sidebarKey)
        onSidebarVisibilityChanged?(expanded)
    }
}
