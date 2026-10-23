import Foundation

/// 发布日 Runbook 的一步（v0.8.3）：相对战役开始日的时间点 + 渠道 + 需要的
/// DPP 运营能力。状态以 `isDone`（人工）与帖子状态派生的 `satisfied` 为准；
/// 不另存一份发布状态。
///
/// Foundation-only，进 harness。
nonisolated struct PromotionRunbookStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// 预热/准备（填表、素材、检查账号）。
        case prepare
        /// 发布（公开动作，必须人工批准）。
        case publish
        /// 跟进（回复首批评论/补充说明）。
        case followUp
        /// 采数据（指标快照）。
        case metrics
        /// 复盘（写经验/调整下周计划）。
        case review

        var label: String {
            switch self {
            case .prepare: String(localized: "Prepare")
            case .publish: String(localized: "Publish")
            case .followUp: String(localized: "Follow up")
            case .metrics: String(localized: "Collect metrics")
            case .review: String(localized: "Review")
            }
        }

        var icon: String {
            switch self {
            case .prepare: "square.and.pencil"
            case .publish: "paperplane"
            case .followUp: "bubble.left.and.bubble.right"
            case .metrics: "chart.line.uptrend.xyaxis"
            case .review: "checkmark.seal"
            }
        }
    }

    var id: UUID
    /// 相对战役 `startsAt` 的天数（-1 = 前一天，0 = 当天，7 = 一周后）。
    var offsetDays: Int
    var title: String
    var kind: Kind
    /// 渠道平台名（与 PromotionPost.platform 对齐；空 = 跨渠道步骤）。
    var platform: String
    /// 需要的 DPP 能力名（opsCompose/opsPublish/opsMetrics/opsReply…）。
    var capability: String?
    var isDone: Bool
    var doneAt: Date?
    var note: String

    init(id: UUID = UUID(), offsetDays: Int, title: String, kind: Kind,
         platform: String = "", capability: String? = nil,
         isDone: Bool = false, doneAt: Date? = nil, note: String = "") {
        self.id = id
        self.offsetDays = offsetDays
        self.title = title
        self.kind = kind
        self.platform = platform
        self.capability = capability
        self.isDone = isDone
        self.doneAt = doneAt
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, offsetDays, title, kind, platform, capability, isDone, doneAt, note
    }

    // 容错解码：后续加字段不破坏已存战役。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        offsetDays = (try? c.decode(Int.self, forKey: .offsetDays)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .prepare
        platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? ""
        capability = (try? c.decodeIfPresent(String.self, forKey: .capability)) ?? nil
        isDone = (try? c.decodeIfPresent(Bool.self, forKey: .isDone)) ?? false
        doneAt = (try? c.decodeIfPresent(Date.self, forKey: .doneAt)) ?? nil
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

/// Runbook 生成与状态派生（纯逻辑）。
nonisolated enum PromotionRunbook {
    enum Template: String, CaseIterable, Identifiable {
        case release
        case feature
        case retro

        var id: String { rawValue }

        var label: String {
            switch self {
            case .release: String(localized: "Release launch")
            case .feature: String(localized: "Feature launch")
            case .retro: String(localized: "Retrospective")
            }
        }

        var summary: String {
            switch self {
            case .release: String(localized: "T-1 teaser · T0 publish · T+1 first-day check · T+7 week review")
            case .feature: String(localized: "T-1 preview · T0 publish · T+3 follow-up · T+7 review")
            case .retro: String(localized: "Review draft · metrics snapshot · lessons")
            }
        }
    }

    /// 按模板生成步骤：release/feature 对每个平台生成一条时间线，
    /// retro 是跨渠道的复盘步骤。
    static func steps(template: Template, version: String?, platforms: [String],
                      start: Date, calendar: Calendar = .current) -> [PromotionRunbookStep] {
        let cleanPlatforms = platforms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let versionLabel = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch template {
        case .release:
            return cleanPlatforms.flatMap { platform -> [PromotionRunbookStep] in
                [
                    PromotionRunbookStep(offsetDays: -1, title: String(localized: "Preview on \(platform)"), kind: .prepare,
                                         platform: platform, capability: "opsCompose"),
                    PromotionRunbookStep(offsetDays: 0, title: String(localized: "Publish on \(platform)"), kind: .publish,
                                         platform: platform, capability: "opsPublish"),
                    PromotionRunbookStep(offsetDays: 1, title: String(localized: "First-day check on \(platform)"), kind: .metrics,
                                         platform: platform, capability: "opsMetrics"),
                    PromotionRunbookStep(offsetDays: 7, title: String(localized: "Week-one review on \(platform)"), kind: .review,
                                         platform: platform, capability: "opsMetrics"),
                ]
            }
        case .feature:
            return cleanPlatforms.flatMap { platform -> [PromotionRunbookStep] in
                [
                    PromotionRunbookStep(offsetDays: -1, title: String(localized: "Preview on \(platform)"), kind: .prepare,
                                         platform: platform, capability: "opsCompose"),
                    PromotionRunbookStep(offsetDays: 0, title: String(localized: "Publish on \(platform)"), kind: .publish,
                                         platform: platform, capability: "opsPublish"),
                    PromotionRunbookStep(offsetDays: 3, title: String(localized: "Follow up on \(platform)"), kind: .followUp,
                                         platform: platform, capability: "opsReply"),
                    PromotionRunbookStep(offsetDays: 7, title: String(localized: "Review on \(platform)"), kind: .review,
                                         platform: platform, capability: "opsMetrics"),
                ]
            }
        case .retro:
            let suffix = versionLabel.isEmpty ? "" : " v\(versionLabel)"
            return [
                PromotionRunbookStep(offsetDays: 0, title: String(localized: "Draft retrospective\(suffix)"), kind: .review),
                PromotionRunbookStep(offsetDays: 1, title: String(localized: "Snapshot metrics"), kind: .metrics,
                                     capability: "opsMetrics"),
                PromotionRunbookStep(offsetDays: 2, title: String(localized: "Write lessons"), kind: .review),
            ]
        }
    }

    /// 步骤落到日历上的日期（战役开始日 + offsetDays，保持同日时刻）。
    static func date(for step: PromotionRunbookStep, start: Date,
                     calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: step.offsetDays, to: start) ?? start
    }

    /// 发布步骤是否已由一条已发帖满足（只认同战役 + 同平台）。
    static func isSatisfied(_ step: PromotionRunbookStep, campaignID: UUID,
                            posts: [PromotionPost]) -> Bool {
        guard step.kind == .publish, !step.platform.isEmpty else { return false }
        return posts.contains {
            $0.campaignID == campaignID
                && $0.status == .published
                && $0.platform == step.platform
        }
    }

    /// 展示用状态：人工完成优先，其次发布步骤的帖子状态。
    static func isComplete(_ step: PromotionRunbookStep, campaignID: UUID,
                           posts: [PromotionPost]) -> Bool {
        step.isDone || isSatisfied(step, campaignID: campaignID, posts: posts)
    }

    static func progress(steps: [PromotionRunbookStep], campaignID: UUID,
                         posts: [PromotionPost]) -> (done: Int, total: Int) {
        let done = steps.filter { isComplete($0, campaignID: campaignID, posts: posts) }.count
        return (done, steps.count)
    }
}
