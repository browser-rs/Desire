import Foundation

/// 上下文压缩：把发给模型的消息裁进预算。
///
/// **口径**：预算按**字符**（与输入框旁的"上下文占用%"同源，非 token —— token 需按
/// 模型分词，端上没有可靠的估算器；已落盘的逐条 `promptTokens` 可以用来校准，见优化清单）。
enum ContextCompaction {
    /// 只裁不留痕。多数调用方用这个；需要"被裁轮次的要点"时用 `compactWithDigest`。
    static func compact(_ messages: [AgentMessage], budget: Int = 160_000) -> [AgentMessage] {
        compactWithDigest(messages, budget: budget).kept
    }

    /// Drops the OLDEST user-started conversation blocks while the estimated
    /// context size exceeds the budget. A block runs from a user message up
    /// to the next user message, so assistant tool_calls and their tool
    /// results always stay together — the provider's tool-call→tool-result
    /// pairing is never broken. The final block is never dropped.
    ///
    /// 同时返回被裁轮次的**机械摘要**（每轮"用户目标｜结论"，非模型生成）：被裁的
    /// 轮次不再是无声消失 —— 模型仍能从前文知道聊过什么（长对话"越聊越忘"的主因）。
    static func compactWithDigest(_ messages: [AgentMessage], budget: Int = 160_000,
                                  digestLimit: Int = 1_500) -> (kept: [AgentMessage], digest: String?) {
        let messages = Self.droppingDanglingToolCalls(messages)
        func size(_ m: AgentMessage) -> Int {
            (m.content?.count ?? 0)
                + (m.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0)
        }
        let sizes = messages.map(size)
        var total = sizes.reduce(0, +)
        guard total > budget else { return (messages, nil) }

        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > 1 else { return (messages, nil) }

        var keepStart = 0
        for (i, s) in starts.enumerated() {
            if total <= budget { break }
            if i == starts.count - 1 { break }   // never drop the final block
            let end = i + 1 < starts.count ? starts[i + 1] : messages.count
            total -= (s..<end).reduce(0) { $0 + sizes[$1] }
            keepStart = end
        }
        guard keepStart > 0 else { return (messages, nil) }

        let kept = Array(messages[keepStart...])
        let digest = Self.digest(for: Array(messages[..<keepStart]), limit: digestLimit)
        return (kept, digest.isEmpty ? nil : digest)
    }

    /// **悬空 tool_calls 清理**：应用在工具执行中途被杀时，最后一条 assistant 的
    /// tool_calls 没有等到结果 —— 原样发给 OpenAI 兼容服务会被直接拒绝
    /// （"assistant message with tool_calls must be followed by tool messages"），
    /// 且之后每一轮都会如此，会话等于报废。这里把**末尾**悬空的调用剥掉（正文保留；
    /// 正文也为空则整条丢弃）。中间的悬空（理论上的坏存储）不动 —— 只处理崩溃形态，
    /// 不猜更多。
    static func droppingDanglingToolCalls(_ messages: [AgentMessage]) -> [AgentMessage] {
        guard var last = messages.last, last.role == .assistant,
              !(last.toolCalls ?? []).isEmpty else { return messages }
        last.toolCalls = nil
        var out = Array(messages.dropLast())
        if !(last.content ?? "").isEmpty { out.append(last) }
        return out
    }

    /// **超长工具结果的请求侧摘要**（0.6.7 工具结果摘要缓存）：kept 轮次里的 tool
    /// 消息若超过阈值，**请求里**替换为「头部摘要 + 重取句柄」——落盘内容保持完整
    /// （面板/轨迹/历史会话都读原文）。模型需要全文时按句柄调 `getToolResult` 取回
    /// （或切片）。只动请求副本（AgentMessage 是值类型），每轮从完整 `messages`
    /// 重建，天然幂等。
    static func summarizingOversizedToolResults(
        _ messages: [AgentMessage],
        threshold: Int = 8_000,
        headChars: Int = 600
    ) -> (messages: [AgentMessage], savedChars: Int) {
        var saved = 0
        var out: [AgentMessage] = []
        out.reserveCapacity(messages.count)
        for message in messages {
            guard message.role == .tool,
                  let content = message.content, content.count > threshold,
                  let callID = message.toolCallId, !callID.isEmpty else {
                out.append(message)
                continue
            }
            let omitted = content.count - headChars
            let stub = String(content.prefix(headChars))
                + "\n[…tool result truncated: \(content.count) chars total, \(omitted) omitted — "
                + "call getToolResult(callId: \"\(callID)\") to read the full content (supports offset/length slices)]"
            saved += content.count - stub.count
            var trimmed = message
            trimmed.content = stub
            out.append(trimmed)
        }
        return (out, saved)
    }

    /// **全数组未配对 tool_calls 清洗**（P0-F）：工具循环中途被取消时，assistant
    /// 的部分 tool_calls 已落结果、其余没有——原样发给 OpenAI 兼容服务会被以
    /// "tool_calls must be followed by tool messages" 拒绝，**且之后每一轮都如此**
    /// （会话报废）。为每个无结果的 tool_call_id 补一条 `[interrupted]` 工具消息
    /// （紧跟其 assistant 之后，保持配对相邻），比剥掉调用更诚实——模型知道
    /// 哪些动作被打断。
    static func repairUnpairedToolCalls(_ messages: [AgentMessage]) -> [AgentMessage] {
        var out: [AgentMessage] = []
        var pendingIDs: [String] = []   // 尚未等到结果的 tool_call_id（按发出顺序）
        for message in messages {
            if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
                out.append(message)
                pendingIDs.append(contentsOf: calls.map(\.id))
                continue
            }
            if message.role == .tool, let toolCallID = message.toolCallId {
                if let idx = pendingIDs.firstIndex(of: toolCallID) {
                    pendingIDs.remove(at: idx)
                }
                out.append(message)
                continue
            }
            // 非工具消息出现在还有未配对调用时（用户中途插话等坏存储形态）：
            // 先补齐配对再放行，维持 "assistant(tool_calls)…tool(result)" 相邻。
            if !pendingIDs.isEmpty {
                for orphan in pendingIDs {
                    out.append(AgentMessage(role: .tool, content: "[interrupted]",
                                            toolCallId: orphan, toolName: nil))
                }
                pendingIDs = []
            }
            out.append(message)
        }
        // 数组末尾仍悬空（被取消的最新形态）：逐个补齐。
        for orphan in pendingIDs {
            out.append(AgentMessage(role: .tool, content: "[interrupted]",
                                    toolCallId: orphan, toolName: nil))
        }
        return out
    }

    /// 被裁轮次的机械摘要：每轮一行"用户目标｜结论"。摘要有上限，更早的只留轮数 ——
    /// 目的是给模型"前文聊过什么"的坐标，不是复述内容。
    private static func digest(for dropped: [AgentMessage], limit: Int) -> String {
        let starts = dropped.indices.filter { dropped[$0].role == .user }
        var lines: [String] = []
        for (i, s) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : dropped.count
            let turn = dropped[s..<end]
            let goal = (dropped[s].content ?? "").replacingOccurrences(of: "\n", with: " ")
            var line = "用户：\(String(goal.prefix(80)))"
            let answer = turn.last(where: { $0.role == .assistant && !($0.content ?? "").isEmpty })?
                .content?.replacingOccurrences(of: "\n", with: " ") ?? ""
            if !answer.isEmpty { line += "｜结论：\(String(answer.prefix(80)))" }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        var out = "以下 \(lines.count) 轮更早的对话已被上下文裁剪，仅保留要点：\n"
            + lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if out.count > limit { out = String(out.prefix(limit)) + "\n（更早的轮次从略）" }
        return out
    }
}
