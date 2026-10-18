import Foundation

/// 收件箱（v26）：把「等你处理的事」与「智能体替你盯着的变化」收成一张清单
/// ——Agent 窗口侧栏新目的地、桥 `GET /inbox` 与离屏快照共用同一份构建逻辑。
///
/// 数据源大半与心跳信号重叠（页面监视变化 / 定时任务失败 / 被打断的回合 /
/// 待回复会话），另外补：待处理互动、被扣下的通知。**构建逻辑是纯函数**
/// （输入抽象成值类型，进 tests/run.sh）；真实收集在 `AgentInboxCollector`。
nonisolated enum AgentInbox {
    enum Kind: String {
        case interrupted
        case unanswered
        case interaction
        case heldNotification
        case watchChange
        case failedRun
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        /// 会话语义的行（被打断/待回复）带它——视图据此跳回对话。
        let conversationID: UUID?
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [Item]
    }

    // MARK: - 输入（值类型；收集在 AgentInboxCollector）

    struct Inputs: Equatable {
        struct Conversation: Equatable {
            let id: UUID
            let title: String
            let excerpt: String
            let updatedAt: Date
            /// 上一回合被打断（会话顶部有"继续/放弃"入口）。
            let hasInterruptedTurn: Bool
            /// 最后一条消息是用户发的（= 在等回复）。
            let lastMessageIsUser: Bool
        }
        struct Run: Equatable {
            let taskName: String
            let error: String?
            let finishedAt: Date
        }
        struct Watch: Equatable {
            let name: String
            let changeCount: Int
            let analysis: String?
            let changedAt: Date?
        }
        struct Interaction: Equatable {
            let id: UUID
            let platform: String
            let author: String
            let excerpt: String
            /// 最后更新时刻（since 过滤用；收件箱展示不看它）。
            let updatedAt: Date
        }
        struct HeldNotification: Equatable {
            let line: String
        }

        var conversations: [Conversation] = []
        var runs: [Run] = []
        var watches: [Watch] = []
        var interactions: [Interaction] = []
        var heldNotifications: [HeldNotification] = []
    }

    // MARK: - 构建（纯逻辑）

    /// 隐藏过滤（忽略/稍后台账）：空节由调用方 prune。
    private static func filterHidden(_ items: [Item], _ hidden: ((String) -> Bool)?) -> [Item] {
        guard let hidden else { return items }
        return items.filter { !hidden($0.id) }
    }

    static let unansweredWindow: TimeInterval = 48 * 3600
    static let perSectionItemCap = 6

    /// - Parameter since: 非 nil 时进入"末次巡检以来"模式：监视变化/任务失败/
    ///   互动只收该时刻之后的（心跳巡检用；收件箱页传 nil = 全量现状）。
    ///   会话部分两种模式一致（48h 窗口 + 待回复）。
    static func build(_ inputs: Inputs, now: Date = Date(), since: Date? = nil,
                      hidden: ((String) -> Bool)? = nil) -> [Section] {
        var action: [Item] = []

        // 被打断的回合（最高优先；同一会话不再重复出现在"待回复"里）。
        var handledConversationIDs = Set<UUID>()
        for conv in inputs.conversations where conv.hasInterruptedTurn {
            handledConversationIDs.insert(conv.id)
            action.append(Item(
                id: "interrupted-\(conv.id.uuidString)",
                kind: .interrupted,
                title: String(localized: "Conversation “\(conv.title)” has an interrupted turn"),
                detail: conv.excerpt.isEmpty
                    ? String(localized: "The last turn did not finish — open it to resume or discard")
                    : "\(conv.excerpt)——" + String(localized: "open it to resume or discard"),
                conversationID: conv.id))
        }

        // 待回复会话：48h 内、最后一条是用户消息。
        let unanswered = inputs.conversations
            .filter { !handledConversationIDs.contains($0.id) }
            .filter { $0.lastMessageIsUser && now.timeIntervalSince($0.updatedAt) < unansweredWindow }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(perSectionItemCap)
        for conv in unanswered {
            action.append(Item(
                id: "unanswered-\(conv.id.uuidString)",
                kind: .unanswered,
                title: String(localized: "Conversation “\(conv.title)” is waiting for your reply"),
                detail: conv.excerpt,
                conversationID: conv.id))
        }

        // 待处理互动（运营台账里没回过的那批）。
        let interactions = inputs.interactions
            .filter { since == nil || $0.updatedAt > since! }
            .prefix(perSectionItemCap)
        for interaction in interactions {
            action.append(Item(
                id: "interaction-\(interaction.id.uuidString)",
                kind: .interaction,
                title: String(localized: "\(interaction.author) left a message on \(interaction.platform)"),
                detail: interaction.excerpt,
                conversationID: nil))
        }

        // 被扣下的通知：聚合成一行（免打扰/预算），可一键补推。
        if !inputs.heldNotifications.isEmpty {
            action.append(Item(
                id: "held-notifications",
                kind: .heldNotification,
                title: String(localized: "\(inputs.heldNotifications.count) notification(s) held (quiet hours / budget)"),
                detail: String(localized: "They ride the next digest automatically — or flush them now"),
                conversationID: nil))
        }

        // 变化与结果：页面监视命中、失败的定时任务。
        var signals: [Item] = []
        let changedWatches = inputs.watches
            .filter { watch in
                guard let changed = watch.changedAt else { return false }
                return since == nil || changed > since!
            }
            .sorted { ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast) }
            .prefix(perSectionItemCap)
        for watch in changedWatches {
            var detail = String(localized: "Content changed (\(watch.changeCount) time(s))")
            if let analysis = watch.analysis?.trimmingCharacters(in: .whitespacesAndNewlines),
               !analysis.isEmpty {
                detail += String(localized: " · AI analysis: \(String(analysis.suffix(160)))")
            }
            signals.append(Item(
                id: "watch-\(watch.name)",
                kind: .watchChange,
                title: String(localized: "Page watch “\(watch.name)”"),
                detail: detail,
                conversationID: nil))
        }
        let failedRuns = inputs.runs
            .filter { since == nil || $0.finishedAt > since! }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(perSectionItemCap)
        for run in failedRuns {
            signals.append(Item(
                id: "run-\(run.taskName)-\(Int(run.finishedAt.timeIntervalSince1970))",
                kind: .failedRun,
                title: String(localized: "Scheduled task “\(run.taskName)” failed"),
                detail: String((run.error ?? "").prefix(160)),
                conversationID: nil))
        }

        return [
            Section(id: "action", title: String(localized: "Needs you"),
                    items: filterHidden(action, hidden)),
            Section(id: "signals", title: String(localized: "Changes & results"),
                    items: filterHidden(signals, hidden)),
        ].filter { !$0.items.isEmpty }
    }

    /// 待办角标（侧栏）：只数"等你处理"，变化类不催。
    static func actionCount(_ sections: [Section]) -> Int {
        sections.first(where: { $0.id == "action" })?.items.count ?? 0
    }
}
