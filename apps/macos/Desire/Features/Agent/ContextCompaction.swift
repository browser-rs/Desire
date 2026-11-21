import Foundation

/// 上下文压缩：把发给模型的消息裁进预算。
///
/// **口径**：预算按**字符**（与输入框旁的"上下文占用%"同源，非 token —— token 需按
/// 模型分词，端上没有可靠的估算器；已落盘的逐条 `promptTokens` 可以用来校准，见优化清单）。
nonisolated enum ContextCompaction {
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
        compactWithDropped(messages, budget: budget, digestLimit: digestLimit).digestTuple
    }

    /// 同 `compactWithDigest`，额外返回**被裁轮次原文**（v0.8.71 批 3）：
    /// 自动压缩路径用它做 ① 归档（数据永不丢）② 旁路语义摘要的输入。
    static func compactWithDropped(_ messages: [AgentMessage], budget: Int = 160_000,
                                   digestLimit: Int = 1_500)
        -> (kept: [AgentMessage], digest: String?, dropped: [AgentMessage],
            digestTuple: (kept: [AgentMessage], digest: String?)) {
        let messages = Self.droppingDanglingToolCalls(messages)
        func size(_ m: AgentMessage) -> Int {
            (m.content?.count ?? 0)
                + (m.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0)
        }
        let sizes = messages.map(size)
        var total = sizes.reduce(0, +)
        guard total > budget else {
            let t = (kept: messages, digest: nil as String?)
            return (messages, nil as String?, [], t)
        }

        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > 1 else {
            let t = (kept: messages, digest: nil as String?)
            return (messages, nil as String?, [], t)
        }

        var keepStart = 0
        for (i, s) in starts.enumerated() {
            if total <= budget { break }
            if i == starts.count - 1 { break }   // never drop the final block
            let end = i + 1 < starts.count ? starts[i + 1] : messages.count
            total -= (s..<end).reduce(0) { $0 + sizes[$1] }
            keepStart = end
        }
        guard keepStart > 0 else {
            let t = (kept: messages, digest: nil as String?)
            return (messages, nil as String?, [], t)
        }

        let kept = Array(messages[keepStart...])
        let dropped = Array(messages[..<keepStart])
        let digest = Self.digest(for: dropped, limit: digestLimit)
        let tuple = (kept: kept, digest: digest.isEmpty ? nil : digest)
        return (kept, tuple.digest, dropped, tuple)
    }

    /// 请求侧"实际会发送"的字符总账（与 `compactWithDigest` 同一裁剪语义，
    /// 只算总账不建数组）——上下文占用芯片用它显示**发送侧**口径。此前芯片
    /// 算落盘全文/预算且封顶 100%：一条 48k 的 HTML 落盘后就永远钉死在
    /// 100% 红色警告，看起来像"压缩没触发"，实际每回合请求都在压缩
    /// （2026-11-15 用户反馈"没有触发自动压缩"的真因）。
    /// - Returns: `total` = 裁剪后总字符；`dropped` = 是否裁掉了最老轮次
    ///   （压缩已生效）；`stuck` = 超预算且没有任何可裁轮次（单轮巨型会话，
    ///   只有这种形态才是真的需要 /new）。
    static func estimatedSentTotal(_ messages: [AgentMessage], budget: Int = 160_000)
        -> (total: Int, dropped: Bool, stuck: Bool) {
        func size(_ m: AgentMessage) -> Int {
            (m.content?.count ?? 0)
                + (m.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0)
        }
        let sizes = messages.map(size)
        let total = sizes.reduce(0, +)
        guard total > budget else { return (total, false, false) }
        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > 1 else { return (total, false, true) }
        var running = total
        var keepStart = 0
        for (i, s) in starts.enumerated() {
            if running <= budget { break }
            if i == starts.count - 1 { break }   // never drop the final block
            let end = i + 1 < starts.count ? starts[i + 1] : messages.count
            running -= (s..<end).reduce(0) { $0 + sizes[$1] }
            keepStart = end
        }
        guard keepStart > 0 else { return (total, false, true) }
        return (running, true, false)
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

    /// **巨型 user/assistant 消息的请求侧封顶**（0.7.6 上下文卫生）：块压缩
    /// "永不丢最后一块"，因此最后一条巨型的用户粘贴/超长回答会**原样进请求**
    /// ——一条消息就能吃掉大半预算且无任何防线（工具消息已有 8k 摘要管线，
    /// 不在此列）。只动请求副本：超限消息保留头 + 尾，中段换成省略标注——
    /// 模型仍能从头尾把握意图，比整条挤爆上下文好。最后一条 user 消息同样
    /// 封顶（截断是显式标注的，模型可提示用户内容过长）。
    static func cappingHugeMessages(
        _ messages: [AgentMessage],
        limit: Int = 40_000,
        headChars: Int = 20_000,
        tailChars: Int = 5_000
    ) -> (messages: [AgentMessage], savedChars: Int) {
        var saved = 0
        var out: [AgentMessage] = []
        out.reserveCapacity(messages.count)
        for message in messages {
            guard message.role == .user || message.role == .assistant,
                  let content = message.content, content.count > limit else {
                out.append(message)
                continue
            }
            let head = String(content.prefix(headChars))
            let tail = String(content.suffix(tailChars))
            let omitted = content.count - headChars - tailChars
            let stub = head
                + "\n[…message truncated: \(content.count) chars total, middle \(omitted) omitted…]\n"
                + tail
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
            if !answer.isEmpty {
                line += "｜结论：\(String(answer.prefix(80)))"
            } else {
                // 无正文回合（只跑了工具就被打断/被裁）：报工具调用摘要——
                // 让模型知道这一轮"做了什么"，而不是只剩一句目标。
                let calls = turn.compactMap { $0.toolCalls }.flatMap { $0 }
                if !calls.isEmpty {
                    let names = calls.prefix(4).map { $0.function.name }.joined(separator: "/")
                    line += "｜执行了 \(calls.count) 次工具调用（\(names)\(calls.count > 4 ? " 等" : "")），无文字结论"
                }
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        var out = "以下 \(lines.count) 轮更早的对话已被上下文裁剪，仅保留要点：\n"
            + lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if out.count > limit { out = String(out.prefix(limit)) + "\n（更早的轮次从略）" }
        // 归档可达性（2026-11-15 持久化压缩）：被裁内容没有消失——完整历史
        // 在会话与归档里，模型需要细节时按关键词检索，而不是凭摘要猜。
        out += "\n（需要细节时用 recallConversation(query) 按关键词检索本会话的完整历史与归档，不要凭要点猜测）"
        return out
    }
}
