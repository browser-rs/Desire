import Foundation

/// 运营数据的**机械洞察**（Foundation-only，进 tests/run.sh）：
/// 平台表现分组统计与发布时段观察——报告与复盘的事实底座。
/// 样本不足时不给结论（宁可不说，不许编）。
nonisolated enum PromotionInsights {

    /// 单平台表现（按平均浏览倒序排）。
    struct PlatformStat: Equatable {
        let platform: String
        let publishedCount: Int
        let weekPublishedCount: Int
        /// 最新浏览均值（只统计有浏览数据的帖）。
        let averageViews: Int?
        let bestTitle: String?
        let bestViews: Int?
    }

    static func platformStats(posts: [PromotionPost], now: Date = Date(),
                              periodDays: Int = 7) -> [PlatformStat] {
        let from = now.addingTimeInterval(-Double(periodDays) * 86_400)
        var groups: [String: [PromotionPost]] = [:]
        for p in posts where p.status == .published {
            groups[p.platform, default: []].append(p)
        }
        return groups.map { platform, list in
            let withViews: [(PromotionPost, Int)] = list.compactMap { p in
                guard let v = p.latestMetrics?.views else { return nil }
                return (p, v)
            }
            let best = withViews.max { $0.1 < $1.1 }
            return PlatformStat(
                platform: platform,
                publishedCount: list.count,
                weekPublishedCount: list.filter { ($0.publishedAt ?? .distantPast) >= from }.count,
                averageViews: withViews.isEmpty ? nil : withViews.map(\.1).reduce(0, +) / withViews.count,
                bestTitle: best?.0.title,
                bestViews: best?.1)
        }
        .sorted { ($0.averageViews ?? -1) > ($1.averageViews ?? -1) }
    }

    /// 发布时段观察：按"周几"聚合浏览均值。
    struct TimingInsight: Equatable {
        let weekdayLabel: String
        let averageViews: Int
        let sampleSize: Int
    }

    /// A/B 变体对比（v0.8.2）：同一平台内按 variantLabel 分组，样本不足
    /// （< minSamples）不出结论。
    struct VariantStat: Equatable {
        let platform: String
        let variant: String
        let publishedCount: Int
        let averageViews: Int
    }

    static func variantStats(posts: [PromotionPost],
                             minSamples: Int = 2) -> [VariantStat] {
        var groups: [String: [PromotionPost]] = [:]
        var labels: [String: (platform: String, variant: String)] = [:]
        for post in posts where post.status == .published {
            guard let variant = post.variantLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines), !variant.isEmpty,
                  post.latestMetrics?.views != nil else { continue }
            let key = post.platform + "|" + variant
            groups[key, default: []].append(post)
            labels[key] = (post.platform, variant)
        }
        return groups.compactMap { key, list -> VariantStat? in
            guard list.count >= max(2, minSamples),
                  let label = labels[key] else { return nil }
            let views = list.compactMap { $0.latestMetrics?.views }
            guard views.count == list.count else { return nil }
            return VariantStat(platform: label.platform, variant: label.variant,
                               publishedCount: list.count,
                               averageViews: views.reduce(0, +) / views.count)
        }
        .sorted {
            if $0.platform != $1.platform { return $0.platform < $1.platform }
            return $0.averageViews > $1.averageViews
        }
    }

    /// 样本 < 3 不给结论（太少说明不了问题，别让模型拿着假信号做决策）。
    static func bestWeekday(posts: [PromotionPost], calendar: Calendar = .current) -> TimingInsight? {
        let withViews: [(Int, Int)] = posts.compactMap { p in
            guard p.status == .published, let at = p.publishedAt,
                  let v = p.latestMetrics?.views else { return nil }
            return (calendar.component(.weekday, from: at), v)
        }
        guard withViews.count >= 3 else { return nil }
        var sums: [Int: (sum: Int, count: Int)] = [:]
        for (wd, v) in withViews {
            var s = sums[wd] ?? (0, 0)
            s.sum += v
            s.count += 1
            sums[wd] = s
        }
        guard let best = sums.max(by: {
            ($0.value.sum / $0.value.count) < ($1.value.sum / $1.value.count)
        }) else { return nil }
        let symbols = calendar.weekdaySymbols
        let label = symbols.indices.contains(best.key - 1) ? symbols[best.key - 1] : "\(best.key)"
        return TimingInsight(weekdayLabel: label,
                             averageViews: best.value.sum / best.value.count,
                             sampleSize: withViews.count)
    }
}
