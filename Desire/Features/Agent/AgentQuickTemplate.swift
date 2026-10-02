import Foundation

/// 用户自定义快捷模板（2026-10-02 个性化增强）：面板快捷按钮行的追加段——
/// 点击把 prompt 填入发送（与固定动作同语义，不进输入历史）。
/// 随 agent_prefs 同步（AgentPrefsSyncPayload.customTemplates）。
struct AgentQuickTemplate: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var prompt: String

    /// 去空白后都空 = 无效（编辑器不收）。
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
