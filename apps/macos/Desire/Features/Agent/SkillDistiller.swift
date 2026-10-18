import Foundation

/// 「从会话提炼技能」的服务半边（v0.7.22 旗舰）：把当前会话的运行记录交给
/// **一次旁路模型调用**（`MemoryExtractor.collectText` 同管道，当前档案口径），
/// 模型按约定回 JSON 草稿，纯逻辑 `SkillDistill` 负责解析。
///
/// 只在**用户显式触发**时跑（面板菜单/桥）；失败（会话太短/模型不可解析）
/// 返回 nil，由调用方如实提示——不静默存一份烂技能。
@MainActor
enum SkillDistiller {

    static func draft(from messages: [AgentMessage],
                      preference: AgentPreferenceStore) async -> SkillDistill.Draft? {
        let transcript = SkillDistill.transcript(from: messages)
        // 一次像样的运行记录才有可提炼的流程（一问一答没有步骤链）。
        guard transcript.count >= 60 else { return nil }
        let system = """
        You distill a completed agent run into a reusable SKILL. Read the RUN TRANSCRIPT and \
        produce a SKILL.md draft: (1) name — a short 2-5 word title; (2) description — one line \
        saying WHEN to use it; (3) instructions — imperative step-by-step notes capturing the \
        actual tool usage, argument shapes, and pitfalls seen in the run. Output ONLY a JSON \
        object: {"name": "...", "description": "...", "instructions": "..."} — no prose, \
        no code fences. (DESIRE_SKILL_DISTILL)
        """
        let output = await MemoryExtractor.collectText(
            preference: preference, system: system, user: transcript)
        return SkillDistill.draft(fromModelOutput: output)
    }
}
