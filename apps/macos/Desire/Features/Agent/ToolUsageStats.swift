import Foundation

/// Agent 工具使用统计（v0.8.6）：从已落盘会话的工具消息派生每个工具的
/// 调用次数 / 失败次数 / 平均耗时。Foundation-only，进 tests/run.sh。
/// 数据口径（诚实边界）：失败只认两种应用自己写的标记——工具结果以
/// `Error: ` 开头（统一失败约定）——与轨迹 `threwError` 同口径；耗时只有
/// 带 `toolDurationMs` 的工具消息才有（老会话可能缺，均值按有耗时的样本算）。
nonisolated enum ToolUsageStats {

    struct ToolStat: Identifiable, Equatable {
        let name: String
        let calls: Int
        let failures: Int
        /// 平均耗时（毫秒）；无耗时样本 = nil。
        let averageMs: Double?

        var id: String { name }
        var failureRate: Double { calls > 0 ? Double(failures) / Double(calls) : 0 }
    }

    /// 汇总输入：逐条工具结果（调用方从会话消息里折出，避免这里依赖
    /// AgentMessage 类型——harness 里用轻量结构测）。
    struct Sample: Equatable {
        let name: String
        /// 工具结果文本（nil = 没有结果消息，仍计一次调用）。
        let resultText: String?
        let durationMs: Double?
        let at: Date
    }

    /// 纯函数：按工具聚合。`since` 只统计该时刻之后的样本（7/30 天窗口）。
    /// 排序：调用次数降序，同数按名字升序（展示稳定）。
    static func derive(from samples: [Sample], since: Date? = nil) -> [ToolStat] {
        let windowed = since.map { cutoff in samples.filter { $0.at >= cutoff } } ?? samples
        guard !windowed.isEmpty else { return [] }

        struct Acc { var calls = 0; var failures = 0; var durationSum = 0.0; var durationCount = 0 }
        var acc: [String: Acc] = [:]
        for sample in windowed {
            var a = acc[sample.name] ?? Acc()
            a.calls += 1
            if let text = sample.resultText, text.hasPrefix("Error: ") {
                a.failures += 1
            }
            if let ms = sample.durationMs {
                a.durationSum += ms
                a.durationCount += 1
            }
            acc[sample.name] = a
        }
        return acc.map { name, a in
            ToolStat(
                name: name,
                calls: a.calls,
                failures: a.failures,
                averageMs: a.durationCount > 0 ? a.durationSum / Double(a.durationCount) : nil
            )
        }
        .sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            return $0.name < $1.name
        }
    }

    /// 会话 → 样本（主线程侧调用方用）。工具消息带 toolName + 结果文本；
    /// assistant 的 toolCalls 只在有对应结果时被计入（结果认领按 callId）。
    static func samples(from conversations: [Conversation]) -> [Sample] {
        var out: [Sample] = []
        for conversation in conversations {
            for message in conversation.messages where message.role == .tool {
                guard let name = message.toolName else { continue }
                out.append(Sample(
                    name: name,
                    resultText: message.content,
                    durationMs: message.toolDurationMs,
                    at: message.createdAt
                ))
            }
        }
        return out
    }
}
