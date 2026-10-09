import Foundation
import os

/// AI 动作复查（guard pass）的**模型调用半边**：复用 MemoryExtractor 的旁路
/// 管道（bypass 档案 → 无则跟随对话模型）发一次轻量评审，8 秒超时——超时/
/// 失败/无法解析统一落 .unsure，由调用方 fail-open。prompt 组装与判定解析
/// 在 AgentGuard（Foundation-only，进 tests/run.sh）。
@MainActor
enum GuardReviewer {
    static let timeoutSeconds: Double = 8

    static func review(
        preference: AgentPreferenceStore,
        input: AgentGuard.Input,
        onUsage: ((Int, Int, String?) -> Void)? = nil
    ) async -> AgentGuard.Verdict {
        await withTaskGroup(of: AgentGuard.Verdict.self) { group in
            group.addTask {
                let text = await MemoryExtractor.collectText(
                    preference: preference,
                    system: AgentGuard.systemPrompt(),
                    user: AgentGuard.userPrompt(for: input),
                    onUsage: onUsage)
                return AgentGuard.parseVerdict(text)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return .unsure
            }
            let first = await group.next() ?? .unsure
            group.cancelAll()
            return first
        }
    }
}
