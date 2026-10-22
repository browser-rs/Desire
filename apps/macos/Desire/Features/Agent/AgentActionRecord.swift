import Foundation

/// Agent 副作用动作审计记录（v0.8.1）。
///
/// 文件写入/编辑保存**动作后**的 SHA-256 与（可选）动作前快照路径：
/// - 撤销前先比对当前文件哈希，用户/其他工具改过就拒绝覆盖（不猜）；
/// - `existedBefore=false` 的撤销 = 删除新文件，同样先比对哈希。
nonisolated struct AgentActionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var tool: String
    var kind: Kind
    var host: String?
    var summary: String
    var path: String?
    var backupPath: String?
    var existedBefore: Bool
    var undoable: Bool
    var afterSHA256: String?
    var createdAt: Date
    var undoneAt: Date?

    enum Kind: String, Codable, CaseIterable {
        case fileWrite
        case fileEdit
        case workflowRun
        case download
        case approval
        case other
    }

    var isUndone: Bool { undoneAt != nil }
    var canUndo: Bool { undoable && !isUndone && path != nil }
}
