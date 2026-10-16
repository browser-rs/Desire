import Foundation

/// 运营定时任务的**单一定义**：每日采集 / 每周复盘两种，名字与提示词在
/// 面板、桥（/promotion/review）、Agent 之间必须一致——名字对不上就会出现
/// "安排过了却显示未安排"。持续学习闭环的自动部分由此承载：
/// 每日采数据（曲线连续）→ 每周复盘（对比增长、沉淀经验、出计划）。
enum PromotionAutomation {
    enum Kind: String, CaseIterable {
        case dailyCollect
        case weeklyReview
        /// 热点选题采集（v0.7.18）：readURL 读热榜 → 提炼 → 选题库。
        case dailyTopics

        var taskName: String {
            switch self {
            case .dailyCollect: return String(localized: "Operations daily collection")
            case .weeklyReview: return String(localized: "Operations review (weekly)")
            case .dailyTopics: return String(localized: "Operations topic scout (daily)")
            }
        }

        var prompt: String {
            switch self {
            case .dailyCollect:
                return """
                运营数据采集（每日）：调用 promotionBrief 看账号、在发内容与互动台账。逐个回访账号主页与已发帖子页（有 DPP 适配包用适配视图，否则 getPageText），用 promotionAccountMetrics / promotionMetrics 采集**今天**的数字——同一对象每天采一次，曲线才连续。后台只能导出报表的场景：页面 PDF 存下来用 readPdf 读数字，截图用 ocrImage。顺带扫一遍新评论/咨询：用 promotionInteractions 批量登记进互动台账（自动去重）；值得回复的逐条拟稿并用 promotionInteractionReply 存 reply，全部贴给用户过目（**别自动回复**，更别编造）。另外看 promotionBrief 的「已到排期」段：有计划今天发的草稿就提醒用户推进（要不要现在过稿/发布）。没有运营数据就回复「暂无运营数据」结束。
                """
            case .weeklyReview:
                return """
                运营复盘（每周）：先调用 promotionBrief（必要时 promotionReport 取周报底稿）读取运营工作台。然后：
                1) 回访各账号主页与已发帖子页（有 DPP 适配包用适配视图，否则 getPageText），用 promotionAccountMetrics / promotionMetrics 采集最新数据；
                2) 对比快照增长，总结本周有效/无效的做法（选题、标题、发布时间、平台差异）；
                3) 用 promotionLesson 记录可复用的结论，完全重复的会被自动跳过；互动台账清一遍：待处理该回的回、回不了的标忽略（promotionInteractionReply）；
                4) 给出下周行动计划（含选题建议，可先用 promotionSave status=idea 存进选题库）；**提议**（别擅自）把关键节点用 addReminder / addCalendarEvent 排进系统提醒与日历——用户点头再落；5) 已达成或已过期的目标提醒用户归档（暂停）或调整。没有数据可复盘就回复「暂无运营数据」并结束。
                """
            case .dailyTopics:
                return """
                热点选题采集（每日）：按「热点选题」（hot-topics）技能的执行流程跑一遍——promotionBrief 读已有选题去重（近几天报过没被挑的方向换掉）→ readURL 读一两类热榜/趋势页（技术社区 + 综合热榜各一条即可；DPP 站点优先 pageExtract）→ 挑 3-5 个与运营目标相关、能写出观点/教程的热点 → 逐条 promotionSave {status:"idea", platform:「来源站点」, title:「题面」, body:"切入角度 + 来源: <url>", goal:「相关目标标题」}（没有匹配目标就不传 goal）。只报实读到的热点、来源链接来自本次返回、不编造热度；选题库里待挑的已堆到 15 条以上就只报增量并提醒用户清一清。采集完把清单（标题+理由+来源）贴给用户挑。
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
        case .dailyTopics: recurrence = .daily(hour: 9, minute: 30)
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
