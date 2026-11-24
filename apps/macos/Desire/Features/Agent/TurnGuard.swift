import Foundation

/// **回合内打转护栏**（v0.8.76 批 2，Foundation-only 进 tests/run.sh）。
///
/// 只提醒、不硬停——硬停由既有的迭代上限负责。分类与阈值同 `TurnProgress`。
///
/// 两条规则，各自在一个回合里只提醒一次：
/// - **同一查看工具第 4 次调用**：真实轨迹里"反复查看"绝大多数是换个参数再看
///   （再执行一个解析脚本、再查一遍目录、再读一片结果），一字不差的重看只有
///   极少数——所以按工具计，不看参数与结果。读大结果的切片最多 3 片，不触发。
/// - **连续 4 个请求全是查看**：看完没动手就接着看。真实数据里最糟的回合正是
///   连续 4 个纯查看请求。
/// **回合发起方**（v0.8.76 批 2）：决定长任务的订阅默认档。用户当场发起的工作
/// 默认"失败时自动汇报"（resume）；定时投递、订阅回报这类系统自己触发的回合
/// 默认只通知（notify）——没人守着的回合不该再烧一个回合。
nonisolated enum TurnOrigin: Equatable, Sendable {
    case user, system
}

nonisolated enum TurnGuard {

    static let sameToolThreshold = 4
    static let streakThreshold = 4

    struct State: Equatable, Sendable {
        /// 本回合内各查看工具的调用次数（动作不打断它）。
        fileprivate(set) var perTool: [String: Int] = [:]
        /// 当前连续的纯查看请求数。
        fileprivate(set) var streak = 0
        fileprivate var sameToolNudged: Set<String> = []
        fileprivate var streakNudged = false

        init() {}
    }

    /// 一个请求的工具调用全部执行完后调用一次（`tools` 按调用顺序）。
    /// 返回应注入**下一个请求**的提醒；nil = 不提醒。
    static func note(requestTools tools: [String], state: inout State) -> String? {
        var lines: [String] = []
        for tool in tools where TurnProgress.isObservation(tool: tool) {
            let count = (state.perTool[tool] ?? 0) + 1
            state.perTool[tool] = count
            if count >= sameToolThreshold, !state.sameToolNudged.contains(tool) {
                state.sameToolNudged.insert(tool)
                lines.append(
                    "\(tool) has now been called \(count) times in this turn. Looking at the same "
                        + "thing again rarely adds information: act on what you already have, or "
                        + "subscribe to completion and end the turn.")
            }
        }
        if TurnProgress.isPureObservationRequest(tools: tools) {
            state.streak += 1
        } else {
            state.streak = 0
        }
        if state.streak >= streakThreshold, !state.streakNudged {
            state.streakNudged = true
            lines.append(
                "The last \(state.streak) requests only looked at state and changed nothing. "
                    + "Decide now: give the user a conclusion, take the next action, or end the turn.")
        }
        guard !lines.isEmpty else { return nil }
        return "[turn guard] " + lines.joined(separator: " ")
    }
}
