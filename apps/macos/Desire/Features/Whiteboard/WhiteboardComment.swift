import Foundation

/// 白板评论（v0.7.24）：批注挂在块 UUID 上（blockID == nil = 整板评论）。
/// 随白板域整板文档同步；resolve 语义 = 已处理（不建模逐设备已读）。
nonisolated struct WhiteboardComment: Codable, Equatable, Identifiable {
    var id: UUID
    /// 目标块（nil = 整板）。块被删后评论保留（blockID 悬空——按"整板"渲染）。
    var blockID: UUID?
    var text: String
    var author: String
    var createdAt: Date
    var resolvedAt: Date?

    /// 单条文本上限（防长文把整板 payload 顶过同步体量护栏）。
    static let maxTextChars = 2000
    /// 单板评论条数上限：满了丢最旧的**已解决**条目；全未解决时丢最旧的。
    static let maxCommentsPerBoard = 200

    init(id: UUID = UUID(), blockID: UUID? = nil, text: String, author: String,
         createdAt: Date = Date(), resolvedAt: Date? = nil) {
        self.id = id
        self.blockID = blockID
        self.text = text
        self.author = author
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    var isOpen: Bool { resolvedAt == nil }

    /// 侧栏展示序（纯函数）：未解决在前，组内新→旧。
    static func ordered(_ comments: [WhiteboardComment]) -> [WhiteboardComment] {
        comments.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            return a.createdAt > b.createdAt
        }
    }

    static func openCount(_ comments: [WhiteboardComment]) -> Int {
        comments.filter(\.isOpen).count
    }
}
