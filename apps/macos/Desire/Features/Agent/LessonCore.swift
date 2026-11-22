import Foundation

/// **教训提取**的纯逻辑半边（v0.8.73 批 1，Foundation-only 进 tests/run.sh）：
/// 失败回合 → 教训记忆（category=correction, source=lesson）的触发判定、
/// 输入构建、产物清洗。旁路调用在 AgentSessionStore（收尾路径），节流记账在
/// AgentMemoryStore（复用 SkillCandidateCore.throttlePasses）。
///
/// 触发纪律沿用机械核验：**只认客观证据**（verificationNote 非空 = 全败/被拒，
/// 或回合失败标记），不凭关键词猜——偶发失败不能固化成错误教训。
nonisolated enum LessonCore {

    /// 触发判定：有客观失败证据才提取（防噪音）。
    static func qualifies(verificationNote: String?, turnFailed: Bool) -> Bool {
        if let note = verificationNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty { return true }
        return turnFailed
    }

    /// 提取输入：用户目标 + 失败工具签名/错误行 + 核验结论。只收失败面
    /// （`Error:` / `[User denied` 前缀——与机械核验同一口径），总长截 8k。
    static func lessonInput(from turn: [AgentMessage], verificationNote: String?) -> String {
        var parts: [String] = []
        if let goal = turn.first(where: { $0.role == .user })?.content {
            parts.append("【目标】" + String(goal.prefix(600)))
        }
        var pendingCalls: [String] = []
        for message in turn {
            if message.role == .assistant, let calls = message.toolCalls {
                for call in calls {
                    pendingCalls.append("\(call.function.name) \(call.function.arguments.prefix(200))")
                }
            }
            if message.role == .tool {
                let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("Error:") || text.hasPrefix("[User denied") {
                    let signature = pendingCalls.last ?? "?"
                    parts.append("【失败】\(signature.prefix(220)) → \(text.prefix(300))")
                }
            }
        }
        if let note = verificationNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            parts.append("【核验】" + note)
        }
        let joined = parts.joined(separator: "\n")
        return joined.count > 8_000 ? String(joined.prefix(8_000)) : joined
    }

    /// 产物清洗：剥代码围栏与引导语前缀，只留本体；超 200 字符截断；
    /// 过短（模型输出空/"无法归因"类拒答）返回 nil。
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = String(text.dropFirst(3))
            if text.hasPrefix("json") { text = String(text.dropFirst(4)) }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["教训：", "教训:", "Lesson: ", "Lesson:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.count >= 8, text.count <= 400 else { return nil }
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        return text
    }
}
