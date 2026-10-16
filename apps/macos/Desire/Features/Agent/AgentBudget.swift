import Foundation

/// 会话 token 预算（v0.7.18）：一个对话的累计用量（`AgentUsage.of` 口径——
/// 含旁路调用，与面板/轨迹/统计同一套数）对预算的评估与文案。**纯逻辑**，
/// 进 tests/run.sh。
///
/// 语义（档位制）：预算 B（0 = 关）。用量到达 `档位 × B` 时回合在**步骤
/// 边界**停下并给一次性说明（"不再静默继续"）；停机即把档位推进到
/// `floor(used/B) + 1`，于是"把预算调大 / 继续说一声"之后可以继续跑到
/// 下一档，而不是一碰上限就永久卡死。80% 起状态行出 chip（预警）。
enum AgentBudget {
    enum State: String {
        /// 预算未启用（等同旧行为）。
        case off
        /// 正常。
        case within
        /// 已到当前档位额度的 80%。
        case warning
        /// 已到当前档位额度（回合会停在步骤边界）。
        case stopped
    }

    /// 当前档位的额度（tokens）；预算关闭时为 0。
    static func allowance(budget: Int, stopLevel: Int) -> Int {
        guard budget > 0 else { return 0 }
        return max(1, stopLevel) * budget
    }

    /// 评估状态：≥额度 = stopped；≥80% 额度 = warning；预算 0 = off。
    static func state(used: Int, budget: Int, stopLevel: Int) -> State {
        let ceiling = allowance(budget: budget, stopLevel: stopLevel)
        guard ceiling > 0 else { return .off }
        if used >= ceiling { return .stopped }
        if used * 5 >= ceiling * 4 { return .warning }
        return .within
    }

    /// 停过一次后的新档位：把当前用量正好划进"已付"区间。
    static func nextStopLevel(used: Int, budget: Int) -> Int {
        guard budget > 0 else { return 1 }
        return max(1, used / budget + 1)
    }

    /// 用量占当前档位额度的百分比（预算关闭 = 0）。
    static func percent(used: Int, budget: Int, stopLevel: Int = 1) -> Int {
        let ceiling = allowance(budget: budget, stopLevel: stopLevel)
        guard ceiling > 0 else { return 0 }
        return Int((Double(used) / Double(ceiling) * 100).rounded())
    }

    /// 停机说明（追加为**可见消息**）：数字、档位与"怎么继续"一次说清。
    /// 文案是会话内容（与"已达最大步数"同族），不走 UI 字符串目录。
    static func stoppedText(used: Int, budget: Int) -> String {
        let u = AgentUsage.formatTokens(used)
        let b = AgentUsage.formatTokens(budget)
        return "⚠️ 会话预算已用尽：本对话已用 \(u) / \(b) tokens，我先停在步骤边界。"
            + "把预算调大（说一句「把预算调到 xx」或经自动化桥 POST /agent/budget）即可继续全速跑；"
            + "每再发一条消息也仍会走一个来回。"
    }
}
