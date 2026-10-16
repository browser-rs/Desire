import Foundation

/// 真实数据收集（MainActor）；构建逻辑在 `AgentInbox.build`（纯函数）。
@MainActor
enum AgentInboxCollector {
    /// 实时输入（UI 与侧栏徽标）：用 app 持有的 store 实例。
    static func liveInputs(conversationStore: ConversationStore) -> AgentInbox.Inputs {
        var inputs = AgentInbox.Inputs()
        inputs.conversations = conversationStore.conversations.map { conv in
            let lastMessage = conv.messages.last
            let excerpt = (lastMessage?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return AgentInbox.Inputs.Conversation(
                id: conv.id,
                title: conv.title,
                excerpt: String(excerpt.prefix(120)),
                updatedAt: conv.updatedAt,
                hasInterruptedTurn: conv.turnActive ?? false,
                lastMessageIsUser: lastMessage?.role == .user && !excerpt.isEmpty)
        }
        inputs.runs = AgentScheduler.shared.runs
            .filter { $0.status == "failed" }
            .compactMap { run in
                guard let finished = run.finishedAt else { return nil }
                return AgentInbox.Inputs.Run(taskName: run.taskName, error: run.error, finishedAt: finished)
            }
        inputs.watches = PageWatchStore.shared.watches.map { watch in
            AgentInbox.Inputs.Watch(name: watch.name,
                                    changeCount: watch.changeCount,
                                    analysis: watch.lastAnalysis,
                                    changedAt: watch.lastChangedAt)
        }
        inputs.interactions = PromotionStore.shared.interactions
            .filter { $0.status == .pending }
            .map { item in
                AgentInbox.Inputs.Interaction(id: item.id,
                                              platform: item.platform,
                                              author: item.author,
                                              excerpt: String(item.text.prefix(140)))
            }
        inputs.heldNotifications = ProactiveNotificationStore.shared.heldLines
            .map { AgentInbox.Inputs.HeldNotification(line: $0) }
        return inputs
    }

    /// 查询输入（桥端点）：会话按"查询读盘"惯例走新实例（视图用实时 store）。
    static func diskInputs() -> AgentInbox.Inputs {
        let diskStore = ConversationStore()
        var inputs = liveInputs(conversationStore: diskStore)
        inputs.conversations = diskStore.conversations.map { conv in
            let lastMessage = conv.messages.last
            let excerpt = (lastMessage?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return AgentInbox.Inputs.Conversation(
                id: conv.id,
                title: conv.title,
                excerpt: String(excerpt.prefix(120)),
                updatedAt: conv.updatedAt,
                hasInterruptedTurn: conv.turnActive ?? false,
                lastMessageIsUser: lastMessage?.role == .user && !excerpt.isEmpty)
        }
        return inputs
    }
}
