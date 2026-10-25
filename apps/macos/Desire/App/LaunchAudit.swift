import Foundation
import os

/// 启动路径审计（v0.8.6）：把散在三处的 "launch phase" lap 汇进同一个内存
/// 记录器，首窗出现时打印 **top 5 耗时步骤** + 预算判定（700ms，ROADMAP
/// 口径）。只做日志，不做 UI。Debug/Release 都打（Release 现场排查启动慢
/// 同样需要；仅两行，噪音可忽略）。
@MainActor
enum LaunchAudit {
    static let budgetMs: Double = 700

    private struct Mark {
        let name: String
        let at: Date
    }

    private nonisolated(unsafe) static var marks: [Mark] = []
    private nonisolated(unsafe) static var summarized = false

    /// 记一个阶段（与既有 lap 日志同点调用）。时间用真钟。
    static func mark(_ name: String) {
        marks.append(Mark(name: name, at: Date()))
    }

    /// 首窗出现时调用一次：打印总耗时、top 5 步骤（相邻 mark 的差分）、
    /// 超预算标红（fault 级）。幂等。
    static func summarize() {
        guard !summarized else { return }
        summarized = true
        guard !marks.isEmpty else { return }

        let start = DesireApp.launchStart
        var steps: [(String, Double)] = []
        var previous = start
        for m in marks {
            steps.append((m.name, m.at.timeIntervalSince(previous) * 1000))
            previous = m.at
        }
        let total = previous.timeIntervalSince(start) * 1000
        let lastWindowGap = Date().timeIntervalSince(previous) * 1000
        let top = steps.sorted { $0.1 > $1.1 }.prefix(5)

        var lines = ["launch audit: total \(Int(total))ms (budget \(Int(budgetMs))ms)"]
        for (name, ms) in top {
            lines.append("  \(name): \(Int(ms))ms")
        }
        if lastWindowGap > 5 {
            lines.append("  (first window): \(Int(lastWindowGap))ms")
        }
        let text = lines.joined(separator: "\n")
        if total > budgetMs {
            Log.app.fault("launch audit OVER BUDGET ⚠️\n\(text, privacy: .public)")
        } else {
            Log.app.info("\(text, privacy: .public)")
        }
    }
}
