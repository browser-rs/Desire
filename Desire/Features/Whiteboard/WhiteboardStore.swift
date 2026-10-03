import Combine
import Foundation

/// 白板存储：**跟着会话走**（同 AgentPlanStore 的定案——按 conversationId
/// 分存，切会话各看各的）。容量兜底只留最近 N 个会话。
/// 一期为进程内存储（重 launch 丢失）；随会话落盘是二期项。
@MainActor
final class WhiteboardStore: ObservableObject {
    static let shared = WhiteboardStore()

    @Published private(set) var boardsByConversation: [String: WhiteboardSpec] = [:]
    @Published private(set) var lastUpdated = Date()

    /// 容量兜底（同计划存储）。
    private static let capacity = 24
    private var insertionOrder: [String] = []

    func board(for conversationID: String?) -> WhiteboardSpec {
        guard let id = conversationID else { return WhiteboardSpec() }
        return boardsByConversation[id] ?? WhiteboardSpec()
    }

    /// 整板替换（render 语义）。
    func set(_ spec: WhiteboardSpec, conversationID: String?) {
        guard let id = conversationID else { return }
        touch(id)
        boardsByConversation[id] = spec
        lastUpdated = Date()
    }

    /// 追加块（append 语义）：无板则建。
    func append(_ blocks: [WhiteboardBlock], title: String?, conversationID: String?) {
        guard let id = conversationID, !blocks.isEmpty else { return }
        touch(id)
        var spec = boardsByConversation[id] ?? WhiteboardSpec(title: title ?? "白板")
        if let title, !title.isEmpty { spec.title = title }
        spec.blocks.append(contentsOf: blocks.filter(\.isValid))
        boardsByConversation[id] = spec
        lastUpdated = Date()
    }

    func clear(conversationID: String?) {
        guard let id = conversationID else { return }
        boardsByConversation[id] = nil
        insertionOrder.removeAll { $0 == id }
        lastUpdated = Date()
    }

    private func touch(_ id: String) {
        if boardsByConversation[id] == nil {
            insertionOrder.append(id)
        }
        while insertionOrder.count > Self.capacity {
            let oldest = insertionOrder.removeFirst()
            boardsByConversation[oldest] = nil
        }
    }
}
