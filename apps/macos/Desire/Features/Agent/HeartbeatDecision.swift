import Foundation

/// 心跳巡检（2026-10-09）的**纯逻辑半边**：
/// 巡检提示词组装 + 模型回复的"说/不说"判定。
///
/// 抑制契约：模型没事时回 `HEARTBEAT_OK`——出现在**开头或
/// 结尾**且剩余文本 ≤300 字符时整条视为静默；出现在中间不特殊处理。判定
/// 宁可漏说不可误扰：解析不出就静默（fail-silent，与 guard pass 的
/// fail-open 同哲学——这里反着，因为心跳的成本是"打扰用户"）。
///
/// Foundation-only：进 tests/run.sh 回归。调用侧在 HeartbeatStore。
nonisolated enum HeartbeatDecision {
    enum Outcome: Equatable {
        case silent
        case speak(String)
    }

    struct Signal {
        let title: String
        let detail: String
    }

    static let okToken = "HEARTBEAT_OK"
    static let maxSuppressRemainder = 300
    static let maxSpeakChars = 600

    // MARK: - Prompt

    static func systemPrompt() -> String {
        """
        You are the periodic heartbeat of a desktop browser agent. You are given the user's \
        standing checklist and a few machine-gathered signals since the last beat. Decide \
        whether the user should be pinged RIGHT NOW.

        Rules:
        - Ping only for things that need timely attention (a page watch flagged "worth \
        attention", a failed scheduled task, an explicit checklist instruction that fires).
        - Never ping for routine completions the user already gets notifications for, and \
        never invent tasks. Do not repeat a ping for the same signal every beat.
        - If nothing needs attention, reply with exactly one word: HEARTBEAT_OK
        - If something needs attention, reply with a short user-facing message \
        (at most 3 sentences, in the user's language). No preamble, no markdown.
        """
    }

    static func userPrompt(checklist: String, signals: [Signal]) -> String {
        var sections: [String] = []
        let list = checklist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !list.isEmpty {
            sections.append("User's standing checklist:\n\(list)")
        }
        if !signals.isEmpty {
            let lines = signals.map { "- \($0.title): \($0.detail)" }
            sections.append("Signals since the last beat:\n\(lines.joined(separator: "\n"))")
        }
        if sections.isEmpty {
            sections.append("(no checklist, no signals)")
        }
        return sections.joined(separator: "\n\n") + "\n\nDecide now: HEARTBEAT_OK or the short ping message."
    }

    // MARK: - 判定

    static func parse(_ text: String) -> Outcome {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥一层代码围栏（小模型爱包 ```）。
        if message.hasPrefix("```") {
            var inner = message.drop(while: { $0 != "\n" }).dropFirst()
            if let fence = inner.range(of: "```", options: .backwards) {
                inner = inner[..<fence.lowerBound]
            }
            message = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !message.isEmpty else { return .silent }

        let upper = message.uppercased()
        let token = okToken.uppercased()
        // 静默契约：OK 在开头或结尾，剩余文本够短（≤300 字符）→ 整条丢弃。
        if upper == token { return .silent }
        if upper.hasPrefix(token) {
            let rest = message.dropFirst(okToken.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：-–—*.! \t\n"))
            if rest.count <= maxSuppressRemainder { return .silent }
        }
        if upper.hasSuffix(token) {
            let rest = message.dropLast(okToken.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：-–—*.! \t\n"))
            if rest.count <= maxSuppressRemainder { return .silent }
        }
        let capped = message.count > maxSpeakChars
            ? String(message.prefix(maxSpeakChars)) + "…"
            : message
        return .speak(capped)
    }
}
