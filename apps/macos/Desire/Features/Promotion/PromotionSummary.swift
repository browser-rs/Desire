import Foundation

/// 运营的**纯派生逻辑**（Foundation-only，进 tests/run.sh）：
/// 目标进度、待发布草稿、近期已发、账号快照与经验清单，以及给斜杠命令/
/// promotionBrief 共用的一份文字摘要（digest）。格式化规则集中在这里，
/// 视图、工具、桥三处不散写。
nonisolated enum PromotionSummary {

    /// 单个目标的进度快照。
    struct GoalProgress: Equatable {
        let goalID: UUID
        let title: String
        let domain: OperationDomain
        let platforms: [String]
        let target: Int?
        let publishedCount: Int
        let draftCount: Int
        let lastPublishedAt: Date?
        /// 有硬指标且已达成；无指标时恒 false（进度只展示不判定）。
        let isComplete: Bool
        /// 有截止且已过期（有指标且未达成；无指标看是否有过产出）。
        let isOverdue: Bool
    }

    static func progress(goals: [PromotionGoal], posts: [PromotionPost],
                         now: Date = Date()) -> [GoalProgress] {
        goals.filter(\.isActive).map { goal in
            let linked = posts.filter { $0.goalID == goal.id }
            let published = linked.filter { $0.status == .published }
            let drafts = linked.filter { $0.status == .draft }
            let complete = goal.targetPosts.map { published.count >= $0 } ?? false
            let overdue = goal.dueDate.map { $0 < now && !complete } ?? false
            return GoalProgress(
                goalID: goal.id,
                title: goal.title,
                domain: goal.domain,
                platforms: goal.platforms,
                target: goal.targetPosts,
                publishedCount: published.count,
                draftCount: drafts.count,
                lastPublishedAt: published.compactMap(\.publishedAt).max(),
                isComplete: complete,
                isOverdue: overdue)
        }
    }

    /// 待审草稿（新起草的在前）——运营工作流的第一干活队列。
    static func outstandingDrafts(posts: [PromotionPost]) -> [PromotionPost] {
        posts.filter { $0.status == .draft }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 选题库（新的在前）——Agent 率先头脑风暴、用户挑选后立项为草稿。
    static func ideas(posts: [PromotionPost]) -> [PromotionPost] {
        posts.filter { $0.status == .idea }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 排期后缀（" · 排期 10-16"）——草稿行用。
    static func planSuffix(_ plannedFor: Date?, now: Date = Date()) -> String {
        guard let plannedFor else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return " · 排期 " + f.string(from: plannedFor)
    }

    /// 近期已发（按发布时间倒序，取前 limit 条）——promotionBrief 用它防重复选题。
    static func recentPublished(posts: [PromotionPost], limit: Int = 8) -> [PromotionPost] {
        posts.filter { $0.status == .published }
            .sorted { ($0.publishedAt ?? $0.createdAt) > ($1.publishedAt ?? $1.createdAt) }
            .prefix(limit)
            .map { $0 }
    }

    /// 文字摘要（斜杠 /promote 与 promotionBrief 同源，防两处口径漂移）。
    static func digest(goals: [PromotionGoal], posts: [PromotionPost],
                       accounts: [PromotionAccount] = [], lessons: [PromotionLesson] = [],
                       now: Date = Date()) -> String {
        var lines: [String] = []

        let progressList = progress(goals: goals, posts: posts, now: now)
        if !progressList.isEmpty {
            lines.append("运营目标（\(progressList.count) 个进行中）：")
            for p in progressList {
                var s = "- [\(p.domain.label)] \(p.title)"
                if !p.platforms.isEmpty { s += " · \(p.platforms.joined(separator: "/"))" }
                if let target = p.target {
                    s += " · 目标 \(target) 条，已发 \(p.publishedCount)"
                    s += p.isComplete ? " ✓" : ""
                } else {
                    s += " · 已发 \(p.publishedCount) 条"
                }
                if p.draftCount > 0 { s += "，草稿 \(p.draftCount)" }
                if p.isOverdue { s += " · ⚠️ 已过期" }
                lines.append(s)
            }
        }

        if !accounts.isEmpty {
            lines.append("账号（\(accounts.count)）：")
            for a in accounts where a.isActive {
                var s = "- [\(a.domain.label)] \(a.platform) · \(a.handle)"
                if let latest = a.latest, let followers = latest.followers {
                    s += " · 粉丝 \(followers)"
                    if let growth = a.followersGrowth, growth != 0 {
                        s += "（\(growth > 0 ? "+" : "")\(growth)）"
                    }
                }
                if a.snapshots.count < 2, a.latest?.followers == nil { s += " · 待采数据" }
                lines.append(s)
            }
        }

        let ideaPosts = ideas(posts: posts)
        if !ideaPosts.isEmpty {
            lines.append("选题库（\(ideaPosts.count)）：")
            for i in ideaPosts.prefix(8) {
                lines.append("- [\(i.platform)] \(i.title)")
            }
        }

        let drafts = outstandingDrafts(posts: posts)
        if !drafts.isEmpty {
            lines.append("待发布草稿（\(drafts.count)）：")
            for d in drafts.prefix(6) {
                var line = "- [\(d.platform)] \(d.title)（\(shortDate(d.createdAt)) 起草"
                if let planned = d.plannedFor {
                    line += "，计划 \(shortDate(planned)) 发"
                }
                line += "）"
                lines.append(line)
            }
        }

        let published = recentPublished(posts: posts, limit: 5)
        if !published.isEmpty {
            lines.append("最近已发：")
            for p in published {
                var s = "- [\(p.platform)] \(p.title)（\(shortDate(p.publishedAt ?? p.createdAt))"
                if let m = p.latestMetrics {
                    var parts: [String] = []
                    if let v = m.views {
                        parts.append("浏览 \(v)" + growthSuffix(p.viewsGrowth))
                    }
                    if let l = m.likes { parts.append("赞 \(l)") }
                    if let c = m.comments { parts.append("评论 \(c)") }
                    if !parts.isEmpty { s += "，" + parts.joined(separator: " · ") }
                }
                s += "）"
                if let url = p.url, !url.isEmpty { s += " \(url)" }
                lines.append(s)
            }
        }

        // 经验：最近 8 条（越新越靠前）——起草前先读，避免重复踩坑。
        if !lessons.isEmpty {
            lines.append("运营经验（\(lessons.count) 条，最近）：")
            for l in lessons.sorted(by: { $0.createdAt > $1.createdAt }).prefix(8) {
                var s = "- \(l.text)"
                if let platform = l.platform { s += "（\(platform)）" }
                lines.append(s)
            }
        }

        if lines.isEmpty {
            lines.append("运营工作台为空：还没有目标、账号、草稿或已发记录。")
        }
        return lines.joined(separator: "\n")
    }

    /// 增长后缀（" （第一→最新 +N）"），无对比数据返回空串。
    static func growthSuffix(_ growth: Int?) -> String {
        guard let growth, growth != 0 else { return "" }
        return growth > 0 ? " (+\(growth))" : " (\(growth))"
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
