import Foundation

/// AI 动作复查（guard pass，2026-10-09）的**纯逻辑半边**：把「计划动作 +
/// 用户既定规则」组装成一次轻量旁路评审的提示词，并把模型输出解析成三值
/// 判定。评审调用在 `GuardReviewer`（bypass 模型管道，8s 超时）；接线在
/// `AgentSessionStore.gate` 的 autoEdit 快捷放行前——FLAG 转审批卡（带理由），
/// 超时/失败/无法解析一律 fail-open：访问等级本身已授权，复查只是加一道
/// 对照，不能反过来卡死回合。
///
/// Foundation-only：提示词组装与判定解析进 tests/run.sh 回归。
/// nonisolated：纯函数、无状态——app target 的默认 MainActor 隔离会让
/// GuardReviewer 的子任务调用报警（Swift 6 下是错误）。
nonisolated enum AgentGuard {
    enum Verdict: Equatable {
        /// 无明确异议（模型放行，或输出无法解析——fail-open）。
        case allow
        /// 模型标记需要用户确认，带一句理由（审批卡上展示）。
        case flag(String)
        /// 输出为空或完全读不出判定——按 fail-open 处理。
        case unsure
    }

    struct Input {
        let toolName: String
        let argumentsJSON: String
        /// 用户可编辑身份提示词（<identity> 层）。
        var identity: String
        /// 常驻个人规则（<output_rules> 层，逐条）。
        var outputRules: [String]
        /// 会话级临时指令（<session_directive> 层）。
        var sessionDirective: String?
    }

    // 复查是热路径（autoEdit 下每个副作用动作一次），上下文必须小。
    static let maxIdentityChars = 1200
    static let maxArgsChars = 900

    // MARK: - Prompt

    static func systemPrompt() -> String {
        """
        You are a safety reviewer for a browser automation agent. You are given ONE planned tool action and the user's standing rules. Decide whether the action should still run silently, or should be confirmed by the user first.

        Flag the action ONLY when it clearly violates a stated user rule, or is destructive/irreversible and clearly beyond the scope of the current task (deleting data, spending money, sending messages, changing account settings, publishing content).

        Do NOT flag routine browsing, reading, ordinary page edits, or form filling for the current task — those are expected at this access level.

        Answer with exactly one line, nothing else:
        VERDICT: ALLOW
        or
        VERDICT: FLAG - <one short reason, in the user's language>
        """
    }

    static func userPrompt(for input: Input) -> String {
        var rules: [String] = []
        let identity = input.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            let clipped = identity.count > maxIdentityChars
                ? String(identity.prefix(maxIdentityChars)) + "…"
                : identity
            rules.append(clipped)
        }
        for rule in input.outputRules.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !rule.isEmpty {
            rules.append("- " + rule)
        }
        if let directive = input.sessionDirective?
            .trimmingCharacters(in: .whitespacesAndNewlines), !directive.isEmpty {
            rules.append("- " + directive)
        }
        let rulesText = rules.isEmpty ? "(none stated)" : rules.joined(separator: "\n")
        var args = input.argumentsJSON
        if args.count > maxArgsChars {
            args = String(args.prefix(maxArgsChars)) + "…"
        }
        return """
        Planned action: \(input.toolName)
        Arguments: \(args)

        User's standing rules:
        \(rulesText)

        Should this action be confirmed with the user first? Answer with one VERDICT line only.
        """
    }

    // MARK: - Parsing

    /// 逐行找第一行含 "VERDICT"（大小写不敏感）的输出：该行含 FLAG → flag
    /// （ FLAG 后面的文本即理由）；含 ALLOW → allow；两个都没有 → 继续扫
    /// 后续行。整段没有任何可识别判定时，看去掉首尾空白后是否以 ALLOW/FLAG
    /// 开头（模型偶尔省略前缀）；再不行 → unsure（fail-open）。
    static func parseVerdict(_ text: String) -> Verdict {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().contains("VERDICT") else { continue }
            if let range = line.range(of: "FLAG", options: .caseInsensitive) {
                return .flag(reason(after: range, in: line))
            }
            if line.range(of: "ALLOW", options: .caseInsensitive) != nil {
                return .allow
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^FLAG", options: [.regularExpression, .caseInsensitive]) != nil {
            let rest = String(trimmed.dropFirst(4))
            return .flag(reasonIsEmpty(rest) ? "flagged by review" : trimSeparators(rest))
        }
        if trimmed.range(of: "^ALLOW", options: [.regularExpression, .caseInsensitive]) != nil {
            return .allow
        }
        return .unsure
    }

    /// "VERDICT: FLAG - 理由" → "理由"：取 FLAG 之后的文本，剥掉冒号/破折
    /// 号/星号等分隔符与空白。剥完为空则给默认理由（调用方仍走审批）。
    private static func reason(after flagRange: Range<String.Index>, in line: String) -> String {
        let rest = String(line[flagRange.upperBound...])
        let trimmed = trimSeparators(rest)
        return trimmed.isEmpty ? "flagged by review" : trimmed
    }

    private static func reasonIsEmpty(_ text: String) -> Bool {
        trimSeparators(text).isEmpty
    }

    private static func trimSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ":：-–—* \t"))
    }
}
