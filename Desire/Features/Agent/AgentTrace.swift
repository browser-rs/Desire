import Foundation

/// 把一条会话编译成**轨迹（Thought → Action → Observation）**：一行一个回合的 JSONL。
///
/// **轨迹从会话本身派生，不另存一份**：会话里已经有目标、工具调用、观察、最终回答、
/// 自评、机械核验与用户评价；唯一派不出来的是**工具耗时**——所以它记在工具消息上、
/// 随会话落盘。好处：历史回合也能导出，且导出的内容与用户看到的永远一致。
///
/// 失败标记只认应用自己写的两种（拒绝执行与 JS 异常），与 `runMechanicalVerification`
/// 同一口径——**不猜**普通文本失败，字段名也如实叫 `denied` / `threwError`。
enum AgentTrace {
    /// 一个回合 = 从一条 user 消息到「下一条 user 之前」的全部内容。
    ///
    /// `price` 把模型 id 换成单价（成本要用它把 token 折算成金额）。不传就只有 token
    /// 没有金额——**这一点是刻意的**：查不到价就不显示钱，而不是显示 0。
    static func turns(of conversation: Conversation,
                      price: ((String?) -> ModelPrice?)? = nil) -> [[String: Any]] {
        let messages = conversation.messages
        let starts = messages.indices.filter { messages[$0].role == .user }
        guard !starts.isEmpty else { return [] }

        let iso = ISO8601DateFormatter()
        var out: [[String: Any]] = []

        for (turnIndex, start) in starts.enumerated() {
            let end = turnIndex + 1 < starts.count ? starts[turnIndex + 1] : messages.count
            let slice = messages[start..<end]
            let goal = messages[start].content ?? ""

            var steps: [[String: Any]] = []
            var pendingCallID: String?
            var answer = ""
            var critique: String?
            var verification: String?
            var feedback: String?

            for message in slice {
                switch message.role {
                case .user:
                    continue
                case .assistant:
                    for call in message.toolCalls ?? [] {
                        pendingCallID = call.id
                        steps.append([
                            "action": call.function.name,
                            "args": String(call.function.arguments.prefix(600)),
                        ])
                    }
                    if let reasoning = message.reasoning, !reasoning.isEmpty,
                       let first = steps.indices.last, steps[first]["thought"] == nil {
                        steps[first]["thought"] = String(reasoning.prefix(600))
                    }
                    if let text = message.content, !text.isEmpty {
                        answer = text
                    }
                    critique = message.critique ?? critique
                    verification = message.verificationNote ?? verification
                    feedback = message.feedback ?? feedback
                case .tool:
                    let text = message.content ?? ""
                    let observation: [String: Any] = [
                        "result": String(text.prefix(800)),
                        "denied": text.hasPrefix("[User denied"),
                        "threwError": text.hasPrefix("Error:"),
                        "ms": message.toolDurationMs.map { ($0 * 10).rounded() / 10 } as Any,
                    ]
                    // 认领最近一个还没观察的调用（顺序与执行顺序一致）。
                    if let index = steps.lastIndex(where: { $0["result"] == nil }) {
                        steps[index].merge(observation) { _, new in new }
                    } else {
                        steps.append(observation)
                    }
                    pendingCallID = nil
                case .system:
                    continue
                }
            }
            _ = pendingCallID

            var turn: [String: Any] = [
                "conversation": conversation.id.uuidString,
                "title": conversation.title,
                "turn": turnIndex + 1,
                "startedAt": iso.string(from: messages[start].createdAt),
                "goal": goal,
                "steps": steps,
                "answer": String(answer.prefix(2000)),
                "toolCalls": steps.count,
            ]
            // token 用量与成本：与面板状态行同一套 `AgentUsage`，口径一致。
            let usage = AgentUsage.of(Array(slice), price: price ?? { _ in nil })
            if !usage.isEmpty {
                turn["tokens"] = ["prompt": usage.promptTokens,
                                  "completion": usage.completionTokens,
                                  "total": usage.totalTokens]
                if let usd = usage.usd { turn["cost"] = (usd * 1_000_000).rounded() / 1_000_000 }
                if usage.hasUnpriced { turn["costIncomplete"] = true }
            }
            // 这一回合实际用的模型（一轮里换过就记最后一个——它给出了最终回答）。
            if let model = slice.last(where: { $0.role == .assistant })?.model, !model.isEmpty {
                turn["model"] = model
            }
            if let critique { turn["critique"] = String(critique.prefix(600)) }
            if let verification { turn["verificationNote"] = String(verification.prefix(600)) }
            if let feedback { turn["feedback"] = feedback }
            out.append(turn)
        }
        return out
    }

    /// 聚合统计：**从同一份轨迹派生**，UI 与桥共用一份口径。这就是"失败模式"要看的东西
    /// ——工具失败/被拒、慢工具、未验证提示、用户评价，全都不需要额外埋点。
    static func stats(of turns: [[String: Any]]) -> [String: Any] {
        var toolCalls = 0
        var denied = 0
        var threwError = 0
        var timedCalls = 0
        var totalMs = 0.0
        var perTool: [String: (calls: Int, failed: Int, totalMs: Double)] = [:]
        var unverified = 0
        var votesUp = 0
        var votesDown = 0
        var promptTokens = 0
        var completionTokens = 0
        var cost = 0.0
        var costTurns = 0
        var unpricedTurns = 0

        for turn in turns {
            for step in (turn["steps"] as? [[String: Any]]) ?? [] {
                guard let action = step["action"] as? String else { continue }
                toolCalls += 1
                let isDenied = step["denied"] as? Bool ?? false
                let isError = step["threwError"] as? Bool ?? false
                if isDenied { denied += 1 }
                if isError { threwError += 1 }
                var entry = perTool[action] ?? (0, 0, 0)
                entry.calls += 1
                if isDenied || isError { entry.failed += 1 }
                if let ms = step["ms"] as? Double {
                    timedCalls += 1
                    totalMs += ms
                    entry.totalMs += ms
                } else if let ms = step["ms"] as? Int {
                    timedCalls += 1
                    totalMs += Double(ms)
                    entry.totalMs += Double(ms)
                }
                perTool[action] = entry
            }
            if let note = turn["verificationNote"] as? String, !note.isEmpty { unverified += 1 }
            if let tokens = turn["tokens"] as? [String: Any] {
                promptTokens += tokens["prompt"] as? Int ?? 0
                completionTokens += tokens["completion"] as? Int ?? 0
            }
            if let turnCost = turn["cost"] as? Double {
                cost += turnCost
                costTurns += 1
            }
            if turn["costIncomplete"] != nil { unpricedTurns += 1 }
            switch turn["feedback"] as? String {
            case "up": votesUp += 1
            case "down": votesDown += 1
            default: break
            }
        }

        let slowest = perTool.compactMap { name, entry -> [String: Any]? in
            guard entry.calls > 0, entry.totalMs > 0 else { return nil }
            return ["tool": name, "calls": entry.calls, "failed": entry.failed,
                    "avgMs": (entry.totalMs / Double(entry.calls) * 10).rounded() / 10]
        }.sorted { ($0["avgMs"] as? Double ?? 0) > ($1["avgMs"] as? Double ?? 0) }

        let flakiest = perTool.compactMap { name, entry -> [String: Any]? in
            guard entry.failed > 0 else { return nil }
            return ["tool": name, "calls": entry.calls, "failed": entry.failed]
        }.sorted { ($0["failed"] as? Int ?? 0) > ($1["failed"] as? Int ?? 0) }

        return [
            "turns": turns.count,
            "toolCalls": toolCalls,
            "denied": denied,
            "threwError": threwError,
            "avgToolMs": timedCalls > 0 ? (totalMs / Double(timedCalls) * 10).rounded() / 10 : 0,
            "unverifiedTurns": unverified,
            "votesUp": votesUp,
            "votesDown": votesDown,
            "promptTokens": promptTokens,
            "completionTokens": completionTokens,
            // 金额只在**每一笔都已定价**时给（等于一个真总额）；只要有一笔没定价就不给，
            // 改用 `costIncomplete` 说明——否则那个数会被当成总额。
            "cost": (costTurns > 0 && unpricedTurns == 0) ? (cost * 1_000_000).rounded() / 1_000_000 : NSNull(),
            "costIncomplete": unpricedTurns > 0,
            "slowestTools": Array(slowest.prefix(5)),
            "flakiestTools": Array(flakiest.prefix(5)),
        ]
    }

    /// 一行一个回合；解析不了的字段（如耗时缺失）写 null，不省略键，方便下游直接用。
    static func jsonl(of conversation: Conversation, limit: Int? = nil,
                      price: ((String?) -> ModelPrice?)? = nil) -> String {
        var turns = turns(of: conversation, price: price)
        if let limit, limit > 0, turns.count > limit { turns = Array(turns.suffix(limit)) }
        let encoder = JSONSerialization.self
        return turns.compactMap { turn -> String? in
            guard let data = try? encoder.data(withJSONObject: turn, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
    }
}
