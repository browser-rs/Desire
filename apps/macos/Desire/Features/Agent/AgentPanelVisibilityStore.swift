import Combine
import Foundation

/// Agent 面板显隐登记（每窗口一份）：通知深链需要知道"点通知时该窗的
/// 面板是否已打开"——打开则只激活应用，未打开才补一条打开命令。
/// 记录点 = 一切写入 showAgentPanel 的路径（命令分发器 + ContentView 各处）。
@MainActor
final class AgentPanelVisibilityStore: ObservableObject {
    static let shared = AgentPanelVisibilityStore()

    private var shownByWindow: [String: Bool] = [:]

    func record(key: String?, shown: Bool) {
        guard let key else { return }
        shownByWindow[key] = shown
    }

    /// 未记录过的窗口视为关闭（面板显隐默认不随会话恢复）。
    func isShown(key: String?) -> Bool {
        guard let key else { return false }
        return shownByWindow[key] ?? false
    }
}
