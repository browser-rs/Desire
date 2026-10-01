import Foundation

/// A multi-step task checklist the agent maintains via the `updatePlan`
/// tool — the user sees live progress (pending / in-progress / done) in the
/// panel, the way modern coding agents render their todo lists.
///
/// **刻意只 import Foundation**：随会话文件落盘（Conversation.planSteps），
/// 要进 `tests/run.sh` 的纯逻辑 harness。
struct AgentPlanStep: Identifiable, Codable {
    /// 视图标识而已，不参与编解码（每次载入新生成）。
    var id = UUID()
    let content: String
    /// pending | in_progress | done
    let status: String

    private enum CodingKeys: String, CodingKey { case content, status }
}
