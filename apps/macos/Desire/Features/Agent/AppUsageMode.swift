import Foundation

/// 使用模式（v0.8.23）：界面层的三种工作方式，与 `AgentMode`
/// （standard/research/writing，工具子集）分层——两套模式互不影响。
///
/// - browser：现状。用户浏览，Agent 在侧栏/浮窗里协作，工具作用于当前窗口。
/// - agentFocus：单窗工作台。对话为主界面，浏览面板收起在后台（离屏仍可读写），
///   必要时展开（Peek，下一批实现）。
/// - hybrid：两个窗口。用户的浏览窗口 + Agent 自己的浏览窗口（独立容器），
///   互不抢焦点、互不切标签。
nonisolated enum AppUsageMode: String, CaseIterable, Codable, Sendable {
    case browser
    case agentFocus
    case hybrid

    var title: String {
        switch self {
        case .browser: return String(localized: "Browser")
        case .agentFocus: return String(localized: "Agent Workspace")
        case .hybrid: return String(localized: "Hybrid")
        }
    }

    var detail: String {
        switch self {
        case .browser:
            return String(localized: "Browse as usual; the agent works beside you in the current window.")
        case .agentFocus:
            return String(localized: "A single workspace for the agent. The browser stays in the background and appears only when needed.")
        case .hybrid:
            return String(localized: "Your window and an isolated agent window side by side — neither steals the other's tabs or focus.")
        }
    }
}

extension Notification.Name {
    /// 使用模式变化（视图与工具面据此重配）。
    static let appUsageModeChanged = Notification.Name("desire.appUsageModeChanged")
}
