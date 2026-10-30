import Foundation

/// 工具级检查点（v0.8.25）的纯逻辑：一个 assistant 消息里的 tool_calls 中，
/// 哪些还没有对应的 tool 结果（= 崩溃/强杀时正在执行的那批）。
///
/// 续跑只自动重放**只读**调用：副作用调用（click/type/navigate…）在崩溃前
/// 可能已经生效，自动重放会重复执行——交回模型按页面现状决定。
nonisolated struct PendingToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

nonisolated enum TurnCheckpointCore {
    /// 未完成的调用（保持原顺序、按 id 去重）。
    static func pendingCalls(toolCalls: [PendingToolCall],
                             completedIDs: Set<String>) -> [PendingToolCall] {
        var seen = Set<String>()
        var out: [PendingToolCall] = []
        for call in toolCalls {
            guard !completedIDs.contains(call.id) else { continue }
            guard seen.insert(call.id).inserted else { continue }
            out.append(call)
        }
        return out
    }

    /// 可从断点自动重放的部分（只读工具）。
    static func replayable(_ calls: [PendingToolCall],
                           isReadonly: (String) -> Bool) -> [PendingToolCall] {
        calls.filter { isReadonly($0.name) }
    }

    /// 续跑说明（作为会话备注给模型）。
    static func note(replayed: Int) -> String {
        "[resume] Re-ran \(replayed) read-only tool call(s) that were in flight when the previous turn was interrupted."
    }
}
