import Foundation

/// 运营周报（纯逻辑，Foundation-only）：从工作台四类数据生成一份 Markdown
/// 简报——目标进度、账号增长、本周已发表现、选题与草稿、本周新增经验。
/// 「下周建议」留占位交给 Agent 补（数据是机械的，建议要有模型判断）。
/// 面板「复制周报」、桥 /promotion/report、Agent 工具 promotionReport 三处同源。
nonisolated enum PromotionReport {

    static func markdown(goals: [PromotionGoal], posts: [PromotionPost],
                         accounts: [PromotionAccount], lessons: [PromotionLesson],
                         interactions: [PromotionInteraction] = [],
                         now: Date = Date(), periodDays: Int = 7) -> String {
        let from = now.addingTimeInterval(-Double(periodDays) * 86_400)
        var out: [String] = []

        if goals.isEmpty && posts.isEmpty && accounts.isEmpty && lessons.isEmpty && interactions.isEmpty {
            return "# 运营周报（\(PromotionSummary.shortDate(from)) ~ \(PromotionSummary.shortDate(now))）\n\n"
                + "工作台为空：还没有目标、账号或内容。先对智能体说「帮我运营」定目标、建账号。\n"
        }

        out.append("# 运营周报（\(PromotionSummary.shortDate(from)) ~ \(PromotionSummary.shortDate(now))）")
        out.append("")

        // ── 目标进度 ──
        let progressList = PromotionSummary.progress(goals: goals, posts: posts, now: now)
        if !progressList.isEmpty {
            out.append("## 目标进度")
            for p in progressList {
                let linked = posts.filter { $0.goalID == p.goalID }
                let weekPublished = linked.filter {
                    $0.status == .published && ($0.publishedAt ?? .distantPast) >= from
                }.count
                var line = "- [\(p.domain.label)] \(p.title)"
                if !p.platforms.isEmpty { line += " · \(p.platforms.joined(separator: "/"))" }
                if let target = p.target {
                    line += " · 已发 \(p.publishedCount)/\(target)"
                } else {
                    line += " · 已发 \(p.publishedCount)"
                }
                if weekPublished > 0 { line += "（本周 +\(weekPublished)）" }
                if p.isComplete { line += " ✓ 达成" }
                if p.isOverdue { line += " ⚠️ 已过期" }
                out.append(line)
            }
            out.append("")
        }

        // ── 账号增长 ──
        let activeAccounts = accounts.filter(\.isActive)
        if !activeAccounts.isEmpty {
            out.append("## 账号增长")
            for a in activeAccounts {
                var line = "- [\(a.domain.label)] \(a.platform) · \(a.handle)"
                if let latest = a.latest, let followers = latest.followers {
                    line += " · 粉丝 \(followers)"
                    if let growth = a.followersGrowth, growth != 0 {
                        line += "（\(growth > 0 ? "+" : "")\(growth)）"
                    }
                } else {
                    line += " · 待采数据"
                }
                let weekSnaps = a.snapshots.filter { $0.at >= from }.count
                if weekSnaps > 0 { line += " · 本周采集 \(weekSnaps) 次" }
                out.append(line)
            }
            out.append("")
        }

        // ── 本周已发（按最新浏览倒序）──
        let weekPublished = posts.filter {
            $0.status == .published && ($0.publishedAt ?? .distantPast) >= from
        }.sorted { ($0.metrics?.views ?? -1) > ($1.metrics?.views ?? -1) }
        if !weekPublished.isEmpty {
            out.append("## 本周已发（\(weekPublished.count)）")
            for p in weekPublished {
                var line = "- [\(p.platform)] \(p.title)"
                if let m = p.latestMetrics {
                    var parts: [String] = []
                    if let v = m.views { parts.append("浏览 \(v)" + PromotionSummary.growthSuffix(p.viewsGrowth)) }
                    if let l = m.likes { parts.append("赞 \(l)") }
                    if let c = m.comments { parts.append("评论 \(c)") }
                    if !parts.isEmpty { line += " — " + parts.joined(separator: " · ") }
                }
                if let url = p.url { line += " · \(url)" }
                out.append(line)
            }
            out.append("")
        }

        // ── 平台表现（全量已发，按平均浏览倒序）──
        let stats = PromotionInsights.platformStats(posts: posts, now: now, periodDays: periodDays)
        if !stats.isEmpty {
            out.append("## 平台表现")
            for stat in stats {
                var line = "- \(stat.platform) · 已发 \(stat.publishedCount)"
                if stat.weekPublishedCount > 0 { line += "（本周 \(stat.weekPublishedCount)）" }
                if let avg = stat.averageViews {
                    line += " · 平均浏览 \(avg)"
                } else {
                    line += " · 待采数据"
                }
                if let bestTitle = stat.bestTitle, let bestViews = stat.bestViews {
                    line += " · 最佳「\(bestTitle)」（浏览 \(bestViews)）"
                }
                out.append(line)
            }
            out.append("")
        }
        if let timing = PromotionInsights.bestWeekday(posts: posts) {
            out.append("## 发布时机")
            out.append("- \(timing.weekdayLabel) 发布的平均浏览最高（\(timing.averageViews)，样本 \(timing.sampleSize) 篇）")
            out.append("")
        }

        // ── 选题与草稿 ──
        let ideas = posts.filter { $0.status == .idea }
            .sorted { $0.createdAt > $1.createdAt }
        let drafts = PromotionSummary.outstandingDrafts(posts: posts)
        if !ideas.isEmpty || !drafts.isEmpty {
            out.append("## 选题与草稿")
            if !ideas.isEmpty {
                out.append("选题库（\(ideas.count)）：")
                for i in ideas.prefix(10) {
                    out.append("- [\(i.platform)] \(i.title)")
                }
            }
            if !drafts.isEmpty {
                out.append("待发布草稿（\(drafts.count)）：")
                for d in drafts.prefix(10) {
                    if let planned = d.plannedFor {
                        out.append("- [\(d.platform)] \(d.title) · 排期 \(PromotionSummary.shortDate(planned))")
                    } else {
                        out.append("- [\(d.platform)] \(d.title) · 未排期")
                    }
                }
            }
            out.append("")
        }

        // ── 互动（本周新增/已回复/待处理）──
        if !interactions.isEmpty {
            let weekNew = interactions.filter { $0.createdAt >= from }.count
            let replied = interactions.filter { $0.status == .replied }.count
            let pending = interactions.filter { $0.status == .pending }
                .sorted { $0.createdAt > $1.createdAt }
            out.append("## 互动")
            var line = "- 本周新增 \(weekNew) 条 · 已回复 \(replied) · 待处理 \(pending.count)"
            if !pending.isEmpty { line += "（回不完的先用 promotionInteractionReply 标忽略）" }
            out.append(line)
            for item in pending.prefix(5) {
                out.append("- [\(item.platform)] \(item.author)：\(item.text)")
            }
            out.append("")
        }

        // ── 本周新增经验 ──
        let weekLessons = lessons.filter { $0.createdAt >= from }
            .sorted { $0.createdAt > $1.createdAt }
        out.append("## 本周新增经验（\(weekLessons.count)）")
        if weekLessons.isEmpty {
            out.append("- 本周没有新增经验——复盘时把验证过的结论写进 promotionLesson。")
        } else {
            for l in weekLessons {
                var line = "- \(l.text)"
                if let platform = l.platform { line += "（\(platform)）" }
                out.append(line)
            }
        }
        out.append("")

        out.append("## 下周建议")
        out.append("")
        out.append("（由智能体结合以上数据与历史经验补充。）")

        return out.joined(separator: "\n")
    }
}
