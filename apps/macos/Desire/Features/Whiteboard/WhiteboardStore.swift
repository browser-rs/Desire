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
    /// 撤销/重做栈（条目带会话 id，恢复按会话就近匹配；不持久化——
    /// 板落盘，撤销历史是会话级的）。覆盖面板编辑**和 Agent 写入**——
    /// Agent 误 clear 也救得回。
    @Published private(set) var undoStack: [(id: String, spec: WhiteboardSpec)] = []
    @Published private(set) var redoStack: [(id: String, spec: WhiteboardSpec)] = []

    /// 容量兜底（同计划存储）。
    private static let capacity = 24
    private static let undoLimit = 50
    private static let storageKey = "whiteboard-boards"
    /// 无活跃 agent 会话时的兜底键（.board 导入/手动创作都落这里）。
    static let defaultKey = "__default"
    private var insertionOrder: [String] = []

    private func resolved(_ id: String?) -> String { id ?? Self.defaultKey }

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
        let id = resolved(conversationID)
        recordUndo(id)
        var spec = board(for: id)
        transform(&spec)
        touch(id)
        boardsByConversation[id] = spec
        lastUpdated = Date()
        persist()
    }

    func board(for conversationID: String?) -> WhiteboardSpec {
        boardsByConversation[resolved(conversationID)] ?? WhiteboardSpec()
    }

    /// 无活跃会话时的回退（桥 /whiteboard 调试用）：最近更新过的板。
    func mostRecentBoard() -> WhiteboardSpec? {
        guard let id = insertionOrder.last else { return nil }
        return boardsByConversation[id]
    }

    /// 整板替换（render 语义）。
    func set(_ spec: WhiteboardSpec, conversationID: String?) {
        let id = resolved(conversationID)
        recordUndo(id)
        touch(id)
        boardsByConversation[id] = spec
        lastUpdated = Date()
        persist()
    }

    /// 追加块（append 语义）：无板则建。
    func append(_ blocks: [WhiteboardBlock], title: String?, conversationID: String?) {
        guard !blocks.isEmpty else { return }
        let id = resolved(conversationID)
        recordUndo(id)
        touch(id)
        var spec = boardsByConversation[id] ?? WhiteboardSpec(title: title ?? "白板")
        if let title, !title.isEmpty { spec.title = title }
        spec.blocks.append(contentsOf: blocks.filter(\.isValid))
        boardsByConversation[id] = spec
        lastUpdated = Date()
        persist()
    }

    func clear(conversationID: String?) {
        let id = resolved(conversationID)
        recordUndo(id)
        boardsByConversation[id] = nil
        insertionOrder.removeAll { $0 == id }
        lastUpdated = Date()
        persist()
    }

    /// 撤销该会话最近一次变更（栈从末端就近找本会话条目）。返回是否撤销了。
    @discardableResult
    func undo(conversationID: String?) -> Bool {
        let rid = resolved(conversationID)
        guard let idx = undoStack.lastIndex(where: { $0.id == rid }) else { return false }
        let entry = undoStack.remove(at: idx)
        redoStack.append((rid, board(for: rid)))
        restore(entry.spec, id: rid)
        return true
    }

    @discardableResult
    func redo(conversationID: String?) -> Bool {
        let rid = resolved(conversationID)
        guard let idx = redoStack.lastIndex(where: { $0.id == rid }) else { return false }
        let entry = redoStack.remove(at: idx)
        undoStack.append((rid, board(for: rid)))
        restore(entry.spec, id: rid)
        return true
    }

    func canUndo(_ conversationID: String?) -> Bool {
        undoStack.contains { $0.id == resolved(conversationID) }
    }

    func canRedo(_ conversationID: String?) -> Bool {
        redoStack.contains { $0.id == resolved(conversationID) }
    }

    /// 每个变更前快照当前板。重做栈在新变更时失效（标准 undo 语义）。
    private func recordUndo(_ id: String) {
        undoStack.append((id, board(for: id)))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// 空板恢复 = 移除条目（与 clear 同形，不占容量名额）。
    private func restore(_ spec: WhiteboardSpec, id: String) {
        if spec == WhiteboardSpec() {
            boardsByConversation[id] = nil
            insertionOrder.removeAll { $0 == id }
        } else {
            boardsByConversation[id] = spec
        }
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
