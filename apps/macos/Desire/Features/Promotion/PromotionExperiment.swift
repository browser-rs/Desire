import Foundation

/// 增长实验（v0.8.3）：假设 → 变体 → 计划样本 → 决策。帖子继续用
/// `PromotionPost.variantLabel` 标记 A/B；实验层只保存"为什么要跑、跑够了没有、
/// 结论是什么"，避免让统计数字自己变成结论。
///
/// Foundation-only，进 harness。
nonisolated struct PromotionExperiment: Identifiable, Codable, Equatable {
    enum Metric: String, Codable, CaseIterable {
        case views
        case likes
        case comments

        var label: String {
            switch self {
            case .views: String(localized: "Views")
            case .likes: String(localized: "Likes")
            case .comments: String(localized: "Comments")
            }
        }
    }

    enum Decision: String, Codable, CaseIterable {
        case running
        case adopted
        case rejected
        case inconclusive

        var label: String {
            switch self {
            case .running: String(localized: "Running")
            case .adopted: String(localized: "Adopted")
            case .rejected: String(localized: "Rejected")
            case .inconclusive: String(localized: "Inconclusive")
            }
        }

        var isOpen: Bool { self == .running }
    }

    var id: UUID
    var title: String
    var hypothesis: String
    /// 绑定战役；nil = 跨战役（按 variantLabel 全量统计）。
    var campaignID: UUID?
    var metric: Metric
    /// 变体标签（与 PromotionPost.variantLabel 对齐，如 A/B）。
    var variants: [String]
    /// 每个变体至少多少篇带指标数据的已发帖，才允许下结论。
    var plannedSamples: Int
    var startedAt: Date
    var endedAt: Date?
    var decision: Decision
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, hypothesis: String = "", campaignID: UUID? = nil,
         metric: Metric = .views, variants: [String] = ["A", "B"],
         plannedSamples: Int = 2, startedAt: Date = Date(), endedAt: Date? = nil,
         decision: Decision = .running, notes: String = "",
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.hypothesis = hypothesis
        self.campaignID = campaignID
        self.metric = metric
        self.variants = Self.cleanVariants(variants)
        self.plannedSamples = max(1, plannedSamples)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.decision = decision
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    nonisolated static func cleanVariants(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, hypothesis, campaignID, metric, variants, plannedSamples,
             startedAt, endedAt, decision, notes, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        hypothesis = (try? c.decodeIfPresent(String.self, forKey: .hypothesis)) ?? ""
        campaignID = (try? c.decodeIfPresent(UUID.self, forKey: .campaignID)) ?? nil
        metric = (try? c.decode(Metric.self, forKey: .metric)) ?? .views
        variants = Self.cleanVariants((try? c.decode([String].self, forKey: .variants)) ?? ["A", "B"])
        plannedSamples = max(1, (try? c.decode(Int.self, forKey: .plannedSamples)) ?? 2)
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? Date()
        endedAt = (try? c.decodeIfPresent(Date.self, forKey: .endedAt)) ?? nil
        decision = (try? c.decode(Decision.self, forKey: .decision)) ?? .running
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? startedAt
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

/// 实验统计与结论门槛（纯逻辑）。
nonisolated enum PromotionExperimentAnalysis {
    struct VariantResult: Equatable {
        var variant: String
        var samples: Int
        var average: Double?
    }

    struct Report: Equatable {
        var metric: PromotionExperiment.Metric
        var plannedSamples: Int
        var variants: [VariantResult]
        var isReady: Bool
        /// 平均指标最高的变体；并列第一或样本不足 = nil。
        var leader: String?
        var detail: String
    }

    static func metricValue(_ post: PromotionPost,
                            metric: PromotionExperiment.Metric) -> Int? {
        switch metric {
        case .views: return post.latestMetrics?.views
        case .likes: return post.latestMetrics?.likes
        case .comments: return post.latestMetrics?.comments
        }
    }

    static func report(experiment: PromotionExperiment, posts: [PromotionPost]) -> Report {
        let variants = experiment.variants
        var results: [VariantResult] = []
        for variant in variants {
            let matching = posts.filter { post in
                guard post.status == .published else { return false }
                guard post.variantLabel == variant else { return false }
                if let campaignID = experiment.campaignID, post.campaignID != campaignID {
                    return false
                }
                return metricValue(post, metric: experiment.metric) != nil
            }
            let values = matching.compactMap { metricValue($0, metric: experiment.metric) }
            results.append(VariantResult(
                variant: variant,
                samples: values.count,
                average: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)))
        }
        let isReady = experiment.plannedSamples > 0
            && results.allSatisfy { $0.samples >= experiment.plannedSamples }
        var leader: String?
        if isReady, let best = results.max(by: { ($0.average ?? -1) < ($1.average ?? -1) }),
           let bestAverage = best.average {
            let tied = results.filter { ($0.average ?? -1) == bestAverage }
            leader = tied.count == 1 ? best.variant : nil
        }
        let detail: String
        if !isReady {
            let short = results.filter { $0.samples < experiment.plannedSamples }
                .map { "\($0.variant) \($0.samples)/\(experiment.plannedSamples)" }
                .joined(separator: " · ")
            detail = "Not enough samples: \(short)"
        } else if let leader {
            detail = "\(leader) leads on \(experiment.metric.rawValue)"
        } else {
            detail = "Tied — no clear winner"
        }
        return Report(metric: experiment.metric,
                      plannedSamples: experiment.plannedSamples,
                      variants: results,
                      isReady: isReady,
                      leader: leader,
                      detail: detail)
    }

    /// 周报/简报里的一行摘要；样本不足绝不写成"某变体胜出"。
    static func summaryLine(experiment: PromotionExperiment, posts: [PromotionPost]) -> String {
        let analysis = report(experiment: experiment, posts: posts)
        let parts = analysis.variants.map { result -> String in
            let avg = result.average.map { String(format: "%.0f", $0) } ?? "—"
            return "\(result.variant) \(result.samples) 篇/均值 \(avg)"
        }
        let head = "[\(experiment.title)] \(parts.joined(separator: " · "))"
        return head + " — " + analysis.detail
    }
}
