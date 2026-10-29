import Foundation

/// Agent **工作自述**（v0.8.22）：把一段会话按"用户目标"切成回合，逐回合派生出
/// 机器可读的汇报——干了什么、用了哪些工具、哪一步失败、最后答了什么。
///
/// 这是"编程工具改进 Agent"的数据底座：结论全部从已落盘的消息派生，不新增
/// 存储、不额外调模型（口径同 AgentTrace：能派生就别存）。缺什么能力/工具
/// 这类**主观信息**由 Agent 自己调用 `reportCapabilityGap` 记录，见
/// AgentGapStore。
///
/// Foundation-only，进 tests/run.sh。
nonisolated struct AgentTurnReport: Codable, Equatable, Sendable {
    struct Failure: Codable, Equatable, Sendable {
        var tool: String
        var callId: String
        var message: String
    }

    /// 1 起的回合序号（最近 `maxTurns` 个）。
    var turn: Int
    var goal: String
    /// success（无失败且有回答）| partial（有失败但有回答）| failed（没有回答）。
    var outcome: String
    /// 实际执行的工具结果条数。
    var steps: Int
    /// 工具名 → 调用次数（来自助手的 tool_calls 意图，含被拒绝/跳过的）。
    var toolCalls: [String: Int]
    var failures: [Failure]
    var critique: String?
    var verification: String?
    var answer: String
}

nonisolated enum AgentWorkReportBuilder {
    /// 按"用户消息"切回合；系统消息忽略，回合外的工具消息丢弃。
    static func build(from messages: [AgentMessage], maxTurns: Int = 20) -> [AgentTurnReport] {
        var turns: [[AgentMessage]] = []
        for message in messages {
            if message.role == .user {
                turns.append([message])
            } else if !turns.isEmpty {
                turns[turns.count - 1].append(message)
            }
        }
        let recent = Array(turns.suffix(max(1, maxTurns)))
        return recent.enumerated().map { index, turn in
            report(index: index + 1, messages: turn)
        }
    }

    private static func report(index: Int, messages: [AgentMessage]) -> AgentTurnReport {
        let goal = messages.first(where: { $0.role == .user })?.content ?? ""
        var toolCounts: [String: Int] = [:]
        var failures: [AgentTurnReport.Failure] = []
        var answer = ""
        var critique: String?
        var verification: String?
        var steps = 0

        for message in messages {
            switch message.role {
            case .assistant:
                if let text = message.content, !text.isEmpty {
                    answer = text
                }
                if let value = message.critique, !value.isEmpty { critique = value }
                if let value = message.verificationNote, !value.isEmpty { verification = value }
                for call in message.toolCalls ?? [] {
                    toolCounts[call.function.name, default: 0] += 1
                }
            case .tool:
                steps += 1
                // 失败口径与应用一致：工具失败一律 `Error: ` 前缀（AGENTS 约定）。
                let text = message.content ?? ""
                if text.hasPrefix("Error:") {
                    failures.append(AgentTurnReport.Failure(
                        tool: message.toolName ?? "tool",
                        callId: message.toolCallId ?? "",
                        message: clip(text, 240)))
                }
            case .user, .system:
                break
            }
        }

        let outcome: String
        if answer.isEmpty {
            outcome = "failed"
        } else if failures.isEmpty {
            outcome = "success"
        } else {
            outcome = "partial"
        }

        return AgentTurnReport(
            turn: index,
            goal: clip(goal, 300),
            outcome: outcome,
            steps: steps,
            toolCalls: toolCounts,
            failures: failures,
            critique: critique.map { clip($0, 400) },
            verification: verification.map { clip($0, 400) },
            answer: clip(answer, 600))
    }

    static func clip(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max))
    }
}
