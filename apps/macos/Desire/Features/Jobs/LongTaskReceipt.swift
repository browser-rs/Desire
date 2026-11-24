import Foundation

/// **长任务回执的统一收尾指引**（v0.8.76 批 2，Foundation-only 进 tests/run.sh）。
///
/// 长任务工具（批量下载、导出、批量文档…）的回执此前各写各的，而且自相矛盾：
/// 一边说 "Do NOT wait or poll in a loop"，一边又告诉模型 "listBatchDownloads
/// reports progress"，却不给出任何被允许的下一步。模型被告知别轮询，却不知道
/// 还能做什么，于是去查进度——真实轨迹里 35% 的请求是纯查看。
///
/// 订阅的真实语义（见 `JobEventCenter`）：成功 → 一条备注 + 一条通知，**不开
/// 回合**；失败 → 自动开一个只做汇报的短回合。所以"订阅后结束回合"对成功路径
/// 是零请求。所有长任务回执都从这里取这句话，防止再各写各的。
nonisolated enum LongTaskReceipt {

    /// `watch` = 该工具对应的订阅调用写法，例如 `watchBackgroundTasks(kind: "batch")`。
    static func nextStep(watch: String) -> String {
        "Background work is running — do NOT poll it. Call \(watch) once, then end this turn: "
            + "on success the user is notified, and if anything fails you are resumed to report it."
    }
}
