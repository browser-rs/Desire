import Foundation

/// 成本预算哨兵（v0.8.19 Agent 基础 8）：日/月预算线（美元，0 = 关），
/// 回合收尾时对账——≥80% 提醒一次、≥100% 例行通知一次（每天各至多一次，
/// UserDefaults 记当天已提醒档位）。成本口径与统计页同源
/// （UsageStats.derive × 用户单价），精确匹配无单价不计入（≥ 语义照既有口径）。
@MainActor
enum CostBudgetMonitor {

    enum Level {
        case none, eighty, full
    }

    struct Budget {
        var daily: Double
        var monthly: Double

        static let zero = Budget(daily: 0, monthly: 0)
    }

    static func budget() -> Budget {
        Budget(
            daily: UserDefaults.standard.double(forKey: "costBudget.daily"),
            monthly: UserDefaults.standard.double(forKey: "costBudget.monthly"))
    }

    /// 当日/当月成本（从已存盘会话派生；与统计页同一来源——
    /// stats.days 的按日成本为 0.8.19 新增字段，无单价日 = nil 走 ≥ 语义）。
    static func currentCosts() -> (day: Double?, month: Double?)? {
        guard let app = AppState.live else { return nil }
        let stats = UsageStats.derive(
            from: app.conversationStore.conversations,
            price: { model in app.aiPreference.usagePrice(for: model) })
        let today = Calendar.current.startOfDay(for: Date())
        let day = stats.days.first { Calendar.current.isDate($0.id, inSameDayAs: today) }?.cost
        let monthPrefix = dayStamp(Date()).prefix(7)
        let monthDays = stats.days.filter { dayStamp($0.id).hasPrefix(monthPrefix) }
        // 当月任一日无单价 → 月度成本不可知（nil）。
        let month: Double? = monthDays.contains { $0.cost == nil }
            ? nil
            : monthDays.reduce(0) { $0 + ($1.cost ?? 0) }
        return (day, month)
    }

    /// 回合收尾对账（AgentSessionStore.processLoop 保存后调用）。
    static func checkAfterTurn() {
        let budget = budget()
        guard budget.daily > 0 || budget.monthly > 0 else { return }
        guard let costs = currentCosts() else { return }
        let dayKey = dayStamp(Date())
        if budget.daily > 0, let spent = costs.day {
            let level: Level = spent >= budget.daily ? .full
                : (spent >= budget.daily * 0.8 ? .eighty : .none)
            notifyIfNeeded(level: level, spent: spent, budget: budget.daily,
                           scope: "daily-\(dayKey)",
                           title: String(localized: "Daily cost budget"))
        }
        if budget.monthly > 0, let spent = costs.month {
            let level: Level = spent >= budget.monthly ? .full
                : (spent >= budget.monthly * 0.8 ? .eighty : .none)
            notifyIfNeeded(level: level, spent: spent, budget: budget.monthly,
                           scope: "monthly-\(monthStamp(Date()))",
                           title: String(localized: "Monthly cost budget"))
        }
    }

    private static func notifyIfNeeded(level: Level, spent: Double, budget: Double,
                                       scope: String, title: String) {
        guard level != .none else { return }
        let key = "costAlert.\(scope).\(level == .full ? "full" : "80")"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let percent = Int((spent / budget * 100).rounded())
        ProactiveNotificationStore.shared.deliver(
            title: title,
            body: String(localized: "\(percent)% used ($\(String(format: "%.2f", spent)) of $\(String(format: "%.2f", budget)))"),
            tier: level == .full ? .urgent : .routine)
    }

    nonisolated static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    nonisolated static func monthStamp(_ date: Date) -> String {
        String(dayStamp(date).prefix(7))
    }
}
