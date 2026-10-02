import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
    /// 本对话的输入历史（面板输入框 ↑/↓ 翻阅）。最新在末尾，可选字段——
    /// 旧会话文件没有它也能解码。
    var inputHistory: [String]?
    /// updatePlan 的任务清单（计划跟着会话走：切回/重启后恢复）。
    var planSteps: [AgentPlanStep]?
    /// **回合进行中检查点**：回合开始置 true 随保存落盘，回合结束（含
    /// 报错/上限/取消）清除。崩溃/强杀后该标志残留 = 回合被打断，重新
    /// 打开时面板给出"继续/放弃"（检查点恢复）。
    var turnActive: Bool?
    /// **会话级临时指令**（2026-10-02 个性化增强）："本次对话用英文"这类
    /// 覆盖——随会话文件落盘、切会话跟随，**不进长期记忆**。注入
    /// <session_directive> 层（仅本会话生效）。
    var directive: String?
}
