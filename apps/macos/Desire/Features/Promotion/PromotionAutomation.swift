import Foundation

/// 运营定时任务的**单一定义**：每日采集 / 每周复盘两种，名字与提示词在
/// 面板、桥（/promotion/review）、Agent 之间必须一致——名字对不上就会出现
/// "安排过了却显示未安排"。持续学习闭环的自动部分由此承载：
/// 每日采数据（曲线连续）→ 每周复盘（对比增长、沉淀经验、出计划）。
enum PromotionAutomation {
    enum Kind: String, CaseIterable {
        case dailyCollect
        case weeklyReview

        var taskName: String {
            switch self {
            case .dailyCollect: return String(localized: "Operations daily collection")
            case .weeklyReview: return String(localized: "Operations review (weekly)")
            }
        }

        var prompt: String {
            switch self {
            case .dailyCollect:
                return """
                运营数据采集（每日）：调用 promotionBrief 看账号与在发内容。逐个回访账号主页与已发帖子页（有 DPP 适配包用适配视图，否则 getPageText），用 promotionAccountMetrics / promotionMetrics 采集**今天**的数字——同一对象每天采一次，曲线才连续。顺带看一眼新评论/新咨询：值得回复的拟好回复草稿贴给用户过目（别自动回，更别编造）。没有运营数据就回复「暂无运营数据」结束。
                """
            case .weeklyReview:
                return """
                运营复盘（每周）：先调用 promotionBrief（必要时 promotionReport 取周报底稿）读取运营工作台。然后：
                1) 回访各账号主页与已发帖子页（有 DPP 适配包用适配视图，否则 getPageText），用 promotionAccountMetrics / promotionMetrics 采集最新数据；
                2) 对比快照增长，总结本周有效/无效的做法（选题、标题、发布时间、平台差异）；
                3) 用 promotionLesson 记录可复用的结论，完全重复的会被自动跳过；
                4) 给出下周行动计划（含选题建议，可先用 promotionSave status=idea 存进选题库）；5) 已达成或已过期的目标提醒用户归档（暂停）或调整。没有数据可复盘就回复「暂无运营数据」并结束。
                """
            }
        }
    }

    /// 幂等安排（同名先删再建）。返回是否成功。
    @MainActor
    @discardableResult
    static func schedule(_ kind: Kind) -> Bool {
        let scheduler = AgentScheduler.shared
        _ = scheduler.remove(named: kind.taskName)
        let recurrence: AgentScheduler.ScheduledTask.Recurrence
        switch kind {
        case .dailyCollect: recurrence = .daily(hour: 21, minute: 0)
        case .weeklyReview: recurrence = .weekly(weekday: 2, hour: 10, minute: 0)
        }
        return scheduler.add(name: kind.taskName, prompt: kind.prompt, recurrence: recurrence) != nil
    }

    @MainActor
    static func remove(_ kind: Kind) {
        _ = AgentScheduler.shared.remove(named: kind.taskName)
    }

    @MainActor
    static func isScheduled(_ kind: Kind) -> Bool {
        AgentScheduler.shared.tasks.contains { $0.name == kind.taskName }
    }
}
