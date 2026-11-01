import Combine
import Foundation

/// 工具结果 → Agent 的草稿收件箱（v0.8.33 融合）：
/// Toolbox 的输出区「问 Agent」把内容放进这里并唤起面板；AgentPanel 取走
/// 后填进输入框。面板未开时也安全——打开时 onAppear 再取一次。
@MainActor
final class AgentDraftInbox: ObservableObject {
    static let shared = AgentDraftInbox()

    @Published private(set) var pending: String?

    func send(_ text: String) {
        pending = text
        NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
    }

    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
