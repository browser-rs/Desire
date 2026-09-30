import Combine
import Foundation

/// A multi-step task checklist the agent maintains via the `updatePlan`
/// tool — the user sees live progress (pending / in-progress / done) in the
/// panel, the way modern coding agents render their todo lists.
struct AgentPlanStep: Identifiable, Codable {
    /// 视图标识而已，不参与编解码（每次载入新生成）。
    var id = UUID()
    let content: String
    /// pending | in_progress | done
    let status: String

    private enum CodingKeys: String, CodingKey { case content, status }
}

@MainActor
final class AgentPlanStore: ObservableObject {
    static let shared = AgentPlanStore()

    /// 计划**跟着会话走**（用户定案）：按 conversationId 分存，面板读
    /// **自己 store 的会话**的计划——切换对话显示对应计划、新建对话自然为空、
    /// 切回来看得见此前的计划。此前是全局单份 + 切换即清空（残留/丢失两头堵）。
    @Published private(set) var plansByConversation: [String: [AgentPlanStep]] = [:]
    @Published private(set) var lastUpdated = Date()

    /// 容量兜底：计划是工作态不是档案，只留最近 N 个会话的。
    private static let capacity = 24
    private var insertionOrder: [String] = []

    func steps(for conversationID: String?) -> [AgentPlanStep] {
        guard let id = conversationID else { return [] }
        return plansByConversation[id] ?? []
    }

    func set(_ steps: [AgentPlanStep], conversationID: String?) {
        guard let id = conversationID else { return }
        if plansByConversation[id] == nil {
            insertionOrder.append(id)
        }
        plansByConversation[id] = steps
        while insertionOrder.count > Self.capacity {
            let oldest = insertionOrder.removeFirst()
            plansByConversation[oldest] = nil
        }
        lastUpdated = Date()
    }

    /// 从会话文件恢复（启动后 loadConversation / resumeLatest 走这里）——
    /// 计划随会话落盘，重开聊天记录计划还在。
    func restore(conversationID: String, _ steps: [AgentPlanStep]?) {
        guard let steps, !steps.isEmpty else { return }
        let id = conversationID
        if plansByConversation[id] == nil {
            insertionOrder.append(id)
        }
        plansByConversation[id] = steps
        while insertionOrder.count > Self.capacity {
            let oldest = insertionOrder.removeFirst()
            plansByConversation[oldest] = nil
        }
    }

    /// 同一会话重开（regenerate）：清该会话的计划，等模型重新 updatePlan。
    /// 换会话/新建会话**不需要**清——按会话分存后各自互不影响。
    func clear(conversationID: String?) {
        guard let id = conversationID else { return }
        plansByConversation[id] = nil
        insertionOrder.removeAll { $0 == id }
        lastUpdated = Date()
    }
}
