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
            var cachedPromptTokens = 0
            var promptPrefixChanges: [String] = []

            for message in slice {
                switch message.role {
                case .user:
                    continue
                case .assistant:
                    for call in message.toolCalls ?? [] {
                        // callId 用于结果认领：并行批之后，工具消息虽然按调用顺序落盘，
                        // 位置配对（lastIndex）也会把结果张冠李戴 —— 必须按 id 精确配对。
                        pendingCallID = call.id
                        steps.append([
                            "action": call.function.name,
                            "args": SecretRedactor.redact(String(call.function.arguments.prefix(600))),
                            "callId": call.id,
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
                    cachedPromptTokens += message.cachedPromptTokens ?? 0
                    if let reason = message.promptPrefixChanged, reason != "first" {
                        promptPrefixChanges.append(reason)
                    }
                case .tool:
                    let text = message.content ?? ""
                    let observation: [String: Any] = [
                        "result": String(text.prefix(800)),
                        "denied": text.hasPrefix("[User denied"),
                        "threwError": text.hasPrefix("Error:"),
                        "ms": message.toolDurationMs.map { ($0 * 10).rounded() / 10 } as Any,
                    ]
                    // 认领：**按 toolCallId 精确配对**。并行批之后，"最近一个没观察的
                    // 步骤"这种位置配对会把结果张冠李戴（实测 3 个并行 readFile 的
                    // 结果全部错位）；旧会话没有 id 的步骤退回位置配对。
                    let claimIndex: Int?
                    if let callID = message.toolCallId,
                       let exact = steps.firstIndex(where: {
                           ($0["callId"] as? String) == callID && $0["result"] == nil
                       }) {
                        claimIndex = exact
                    } else {
                        claimIndex = steps.lastIndex(where: { $0["result"] == nil })
                    }
                    if let index = claimIndex {
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

            // **推进度量**（v0.8.76 批 1）：每步按 查看/动作/中性 归类（分类在
            // TurnProgress，与护栏同源）；"请求"按助手消息数——主回合里一条
            // 助手消息就是一次模型调用。
            let progressSteps: [TurnProgress.Step] = steps.compactMap { step in
                guard let action = step["action"] as? String else { return nil }
                return TurnProgress.Step(tool: action,
                                         arguments: step["args"] as? String ?? "",
                                         result: step["result"] as? String ?? "")
            }
            var modelRequests = 0
            var observeRequests = 0
            var observationStreak = 0
            var longestObservationStreak = 0
            for message in slice where message.role == .assistant {
                let names = (message.toolCalls ?? []).map(\.function.name)
                modelRequests += 1
                if TurnProgress.isPureObservationRequest(tools: names) {
                    observeRequests += 1
                    observationStreak += 1
                    longestObservationStreak = max(longestObservationStreak, observationStreak)
                } else {
                    observationStreak = 0
                }
            }
            var turn: [String: Any] = [
                "conversation": conversation.id.uuidString,
                "title": conversation.title,
                "turn": turnIndex + 1,
                "startedAt": iso.string(from: messages[start].createdAt),
                "goal": goal,
                "steps": steps,
                "answer": String(answer.prefix(2000)),
                "toolCalls": steps.count,
                "modelRequests": modelRequests,
                "observeRequests": observeRequests,
                // 回合内最长"连续几个请求全是查看"——打转的直接形态。
                "longestObservationStreak": longestObservationStreak,
                "progress": TurnProgress.dictionary(TurnProgress.summarize(progressSteps)),
            ]
            // token 用量与成本：与面板状态行同一套 `AgentUsage`，口径一致。
            let usage = AgentUsage.of(Array(slice), price: price ?? { _ in nil })
            if !usage.isEmpty {
                turn["tokens"] = ["prompt": usage.promptTokens,
                                  "completion": usage.completionTokens,
                                  "total": usage.totalTokens]
                if let usd = usage.usd { turn["cost"] = (usd * 1_000_000).rounded() / 1_000_000 }
                if usage.hasUnpriced { turn["costIncomplete"] = true }
                // 缓存读数（v0.8.81 批 3）：命中量/命中率 + 本回合前缀变化来源。
                var cache: [String: Any] = ["cached": cachedPromptTokens,
                                            "hitRate": usage.promptTokens > 0
                                                ? (Double(cachedPromptTokens) / Double(usage.promptTokens) * 10000).rounded() / 10000
                                                : 0]
                if !promptPrefixChanges.isEmpty {
                    cache["prefixChanges"] = Array(Set(promptPrefixChanges)).sorted()
                }
                turn["cache"] = cache
            }
            // 成本拆分（v0.7.27）：主回合/子代理/旁路逐组（复用 CostBreakdown，
            // 与面板成本弹层同一口径）；最多 8 组，避免轨迹膨胀。
            let breakdown = CostBreakdown.derive(Array(slice), price: price ?? { _ in nil })
            if !breakdown.groups.isEmpty {
                turn["costGroups"] = breakdown.groups.prefix(8).map { group -> [String: Any] in
                    var row: [String: Any] = ["category": group.category,
                                              "tokens": group.totalTokens]
                    if let kind = group.kind { row["kind"] = kind }
                    if let model = group.model { row["model"] = model }
                    if let usd = group.usd { row["usd"] = (usd * 1_000_000).rounded() / 1_000_000 }
                    return row
                }
            }
            // 这一回合实际用的模型（一轮里换过就记最后一个——它给出了最终回答）。
            if let model = slice.last(where: { $0.role == .assistant })?.model, !model.isEmpty {
                turn["model"] = model
            }
            // 性能真值（v0.8.75 批 1）：本回合每次模型调用的 TTFT/总时长
            // （0.8.74 批 3 落在消息上）——轨迹页 chips 的数据源。
            let ttftValues = slice.compactMap { $0.role == .assistant ? $0.modelTTFTMs : nil }.sorted()
            let latencyValues = slice.compactMap { $0.role == .assistant ? $0.modelLatencyMs : nil }
            if !ttftValues.isEmpty {
                turn["modelCalls"] = ttftValues.count
                turn["ttftP50Ms"] = (ttftValues[ttftValues.count / 2] * 10).rounded() / 10
                turn["modelLatencySumMs"] = (latencyValues.reduce(0, +) * 10).rounded() / 10
            }
            // 路由审计（v0.7.26）：既有 RoutingProvider 的 "via X" 落在消息上，
            // 轨迹照抄——审计页/导出都能回答"这回合到底谁跑的"。
            if let route = slice.last(where: { $0.role == .assistant })?.routeReason, !route.isEmpty {
                turn["route"] = route
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
        var ttftSamples: [Double] = []
        var modelLatencySum = 0.0
        var latencyTurns = 0
        // 推进度量聚合（v0.8.76 批 1）——重复任务熟练度的验收尺。
        var modelRequests = 0
        var observeRequests = 0
        var progressQueries = 0
        var repeatedSameResult = 0
        var repeatedChangedResult = 0
        var observations = 0
        var actions = 0
        var exploreSum = 0
        var exploreMax = 0
        var exploreTurns = 0
        var trailingObservationTurns = 0
        var repeatToolObservations = 0
        var spinningTurns = 0

        for turn in turns {
            modelRequests += turn["modelRequests"] as? Int ?? 0
            observeRequests += turn["observeRequests"] as? Int ?? 0
            repeatToolObservations += (turn["progress"] as? [String: Any])?["repeatToolObservations"] as? Int ?? 0
            // 打转回合：连续 ≥4 个纯查看请求，或同一查看工具 ≥4 次（护栏阈值同此）。
            if (turn["longestObservationStreak"] as? Int ?? 0) >= 4
                || ((turn["progress"] as? [String: Any])?["maxSameToolObservations"] as? Int ?? 0) >= 4 {
                spinningTurns += 1
            }
            if let progress = turn["progress"] as? [String: Any] {
                progressQueries += progress["progressQueries"] as? Int ?? 0
                repeatedSameResult += progress["repeatedSameResult"] as? Int ?? 0
                repeatedChangedResult += progress["repeatedChangedResult"] as? Int ?? 0
                observations += progress["observations"] as? Int ?? 0
                actions += progress["actions"] as? Int ?? 0
                if let explore = progress["exploreBeforeFirstAction"] as? Int {
                    exploreSum += explore
                    exploreMax = max(exploreMax, explore)
                    exploreTurns += 1
                }
                // 以 ≥3 步查看收尾的回合：看完没动手就结束。
                if (progress["trailingObservations"] as? Int ?? 0) >= 3 { trailingObservationTurns += 1 }
            }
            if let p50 = turn["ttftP50Ms"] as? Double { ttftSamples.append(p50) }
            if let sum = turn["modelLatencySumMs"] as? Double {
                modelLatencySum += sum
                latencyTurns += 1
            }
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
            "modelRequests": modelRequests,
            "observeRequests": observeRequests,
            // 纯查看请求占比（0–100 的整数）：长任务里这部分就是在轮询进度。
            "observeRequestRatio": modelRequests > 0
                ? (Double(observeRequests) / Double(modelRequests) * 100).rounded() : 0,
            "progressQueries": progressQueries,
            "observations": observations,
            "actions": actions,
            "repeatToolObservations": repeatToolObservations,
            "repeatedSameResult": repeatedSameResult,
            "repeatedChangedResult": repeatedChangedResult,
            "spinningTurns": spinningTurns,
            "exploreBeforeFirstActionSum": exploreSum,
            "exploreBeforeFirstActionMax": exploreMax,
            "trailingObservationTurns": trailingObservationTurns,
            "ttftP50Ms": ttftSamples.isEmpty ? 0 : (ttftSamples.sorted()[ttftSamples.count / 2] * 10).rounded() / 10,
            "modelLatencySumMs": (modelLatencySum * 10).rounded() / 10,
            "latencyTurns": latencyTurns,
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
