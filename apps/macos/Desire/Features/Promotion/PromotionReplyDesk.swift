import Foundation

/// 互动回复台（v0.8.3，纯逻辑）：按等待时长与类型排出优先级，给 UI 一个
/// 稳定的队列；回复动作仍然"填表不发送"，发送由用户完成。
///
/// Foundation-only，进 harness。
nonisolated enum PromotionReplyDesk {
    enum AgeBucket: String, Comparable {
        case fresh
        case aging
        case overdue

        private var order: Int {
            switch self {
            case .overdue: 0
            case .aging: 1
            case .fresh: 2
            }
        }

        static func < (lhs: AgeBucket, rhs: AgeBucket) -> Bool { lhs.order < rhs.order }

        var label: String {
            switch self {
            case .fresh: String(localized: "Fresh")
            case .aging: String(localized: "Aging")
            case .overdue: String(localized: "Overdue")
            }
        }
    }

    enum Priority: Int, Comparable {
        case normal = 0
        case high = 1
        case urgent = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .normal: String(localized: "Normal")
            case .high: String(localized: "High")
            case .urgent: String(localized: "Urgent")
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let interaction: PromotionInteraction
        let ageHours: Double
        let bucket: AgeBucket
        let priority: Priority

        var id: UUID { interaction.id }
    }

    static let warnHours: Double = 24
    static let overdueHours: Double = 72

    /// 全量队列（含已回复/已忽略，便于回看）；排序 = 待处理优先 →
    /// 超时优先 → 高优先级优先 → 更旧的优先。
    static func rows(interactions: [PromotionInteraction],
                     now: Date = Date(),
                     warnAfterHours: Double = 24,
                     overdueAfterHours: Double = 72) -> [Row] {
        interactions.map { item -> Row in
            let age = max(0, now.timeIntervalSince(item.createdAt)) / 3600
            let bucket: AgeBucket
            if age >= overdueAfterHours { bucket = .overdue }
            else if age >= warnAfterHours { bucket = .aging }
            else { bucket = .fresh }
            let priority: Priority
            switch item.kind {
            case .mention, .dm: priority = .high
            case .comment, .review: priority = .normal
            }
            return Row(interaction: item, ageHours: age, bucket: bucket, priority: priority)
        }
        .sorted { lhs, rhs in
            let lhsPending = lhs.interaction.status == .pending
            let rhsPending = rhs.interaction.status == .pending
            if lhsPending != rhsPending { return lhsPending }
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.interaction.createdAt < rhs.interaction.createdAt
        }
    }

    struct Summary: Equatable {
        var pending: Int
        var overdue: Int
        var replied: Int
        var ignored: Int
        var total: Int

        var replyRate: Int {
            total == 0 ? 0 : Int((Double(replied) / Double(total)) * 100)
        }
    }

    static func summary(interactions: [PromotionInteraction], now: Date = Date(),
                        overdueAfterHours: Double = 72) -> Summary {
        let pendingItems = interactions.filter { $0.status == .pending }
        let overdue = pendingItems.filter {
            now.timeIntervalSince($0.createdAt) / 3600 >= overdueAfterHours
        }.count
        return Summary(
            pending: pendingItems.count,
            overdue: overdue,
            replied: interactions.filter { $0.status == .replied }.count,
            ignored: interactions.filter { $0.status == .ignored }.count,
            total: interactions.count)
    }

    /// 从 DPP `opsReply` 动作里取第一个 fill 步骤的选择器（只读声明，
    /// 不执行动作）。回复台优先用它填表；没有就退回复用选择器。
    static func dppReplySelector(from proto: DesireProtocol?) -> String? {
        guard let action = proto?.actions.first(where: { $0.name == "opsReply" }),
              let raw = action.run?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for step in steps {
            if let fill = step["fill"] as? [String: Any],
               let selector = fill.keys.first, !selector.isEmpty {
                return selector
            }
        }
        return nil
    }

    /// 给 Agent 的拟稿提示（不自动发送）。
    static func draftPrompt(for item: PromotionInteraction, channel: String? = nil) -> String {
        var text = "处理互动台账里的这条（id=\(item.id.uuidString)）：[\(item.platform)] \(item.author) 说「\(item.text)」"
        if let url = item.url, !url.isEmpty { text += "（\(url)）" }
        if let channel, !channel.isEmpty { text += "；渠道语气：\(channel)" }
        text += "。先拟一条回复贴给我确认；我点头后优先用 DPP 的 opsReply 填入（只填不提交），我按发送后再用 promotionInteractionReply 标记 replied；不想回就标 ignored。"
        return text
    }

    /// 渠道无关的安全回复起手式（用户可编辑；不承诺功能/时间）。
    static func template(for kind: PromotionInteraction.Kind) -> String {
        switch kind {
        case .mention:
            return String(localized: "Thanks for mentioning us — happy to answer any questions.")
        case .dm:
            return String(localized: "Thanks for reaching out. What would you like help with?")
        case .comment:
            return String(localized: "Thanks for the feedback — noted.")
        case .review:
            return String(localized: "Thanks for taking the time to review us.")
        }
    }
}
