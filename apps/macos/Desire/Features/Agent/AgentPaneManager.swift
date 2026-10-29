import Combine
import Foundation

/// 专注模式的**内嵌浏览面板**（v0.8.23）：一个独立的 `TabManager`，用 Agent
/// 专用容器（cookie 隔离），标签随会话落盘（session key = `agent-pane`），
/// 但不属于任何窗口——折叠时 webview 移出视图层级仍可导航/取文/执行 JS
///（S1/S2 spike 已验证），展开（Peek，下一批）时才放进工作台渲染。
///
/// 必须停掉挂起计时器：面板标签不是"后台浏览标签"，被挂起会打断 Agent 任务。
@MainActor
final class AgentPaneManager: ObservableObject {
    static let shared = AgentPaneManager()
    static let sessionKey = "agent-pane"

    @Published private(set) var manager: TabManager?

    private init() {}

    @discardableResult
    func ensure() -> TabManager {
        if let manager { return manager }
        guard let app = AppState.live else { return TabManager(headless: true) }
        let created = TabManager()
        created.stopSuspendTimer()
        created.sessionKey = Self.sessionKey
        created.defaultContainerID = WindowRoleRegistry.shared.agentContainerID()
        if let session = TabSessionCoordinator.shared.session(forKey: Self.sessionKey),
           !session.tabs.isEmpty {
            created.apply(session: session,
                          javaScriptEnabled: app.settings.isJavaScriptEnabled,
                          contentBlocker: app.contentBlocker,
                          videoAdBlocker: app.videoAdBlocker)
        } else {
            created.addTab(javaScriptEnabled: app.settings.isJavaScriptEnabled,
                           contentBlocker: app.contentBlocker,
                           videoAdBlocker: app.videoAdBlocker,
                           makeActive: true)
        }
        WindowRoleRegistry.shared.register(sessionKey: Self.sessionKey, role: .agentPane,
                                           containerID: created.defaultContainerID)
        manager = created
        return created
    }
}
