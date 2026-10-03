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
    private static let storageKey = "whiteboard-boards"
    private var insertionOrder: [String] = []

    private init() {
        // 持久化（二期）：重启后板还在。测试实例与用户实例共享 storage
        // 目录——按 conversationId 隔离，互不可见，容量兜底滚动淘汰。
        if let saved = DiskStore.load([String: WhiteboardSpec].self, key: Self.storageKey) {
            boardsByConversation = saved
            insertionOrder = Array(saved.keys)
        }
    }

    private func persist() {
        DiskStore.save(boardsByConversation, key: Self.storageKey)
    }

    /// 块管理（面板编辑）：读当前板 → 变换 → 写回（触发渲染推送 + 落盘）。
    func apply(_ transform: (inout WhiteboardSpec) -> Void, conversationID: String?) {
        guard let id = conversationID else { return }
        var spec = board(for: id)
        transform(&spec)
        touch(id)
        boardsByConversation[id] = spec
        lastUpdated = Date()
        persist()
    }

    func board(for conversationID: String?) -> WhiteboardSpec {
        guard let id = conversationID else { return WhiteboardSpec() }
        return boardsByConversation[id] ?? WhiteboardSpec()
    }

    /// 无活跃会话时的回退（桥 /whiteboard 调试用）：最近更新过的板。
    func mostRecentBoard() -> WhiteboardSpec? {
        guard let id = insertionOrder.last else { return nil }
        return boardsByConversation[id]
    }

    /// 整板替换（render 语义）。
    func set(_ spec: WhiteboardSpec, conversationID: String?) {
        guard let id = conversationID else { return }
        touch(id)
        boardsByConversation[id] = spec
        lastUpdated = Date()
        persist()
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
        persist()
    }

    func clear(conversationID: String?) {
        guard let id = conversationID else { return }
        boardsByConversation[id] = nil
        insertionOrder.removeAll { $0 == id }
        lastUpdated = Date()
        persist()
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
