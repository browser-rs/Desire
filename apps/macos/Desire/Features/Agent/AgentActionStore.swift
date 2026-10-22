import Combine
import CryptoKit
import Foundation
import os

/// Agent 副作用动作审计（v0.8.1）：文件写入/编辑保留旧内容快照，可撤销；
/// 工作流/下载等不可逆动作只记录、明确标记"不可撤销"。
@MainActor
final class AgentActionStore: ObservableObject {
    static let shared = AgentActionStore()

    @Published private(set) var records: [AgentActionRecord] = []

    private let storageKey = "agent-actions"
    private let maxRecords = 200
    private let maxSnapshotBytes = 8 * 1024 * 1024
    let undoDirectory: URL

    enum StoreError: LocalizedError {
        case notFound
        case notUndoable
        case fileChanged
        case backupMissing(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "Action not found."
            case .notUndoable: "This action can't be undone."
            case .fileChanged: "The file changed after this action — refusing to overwrite it."
            case .backupMissing(let path): "The undo snapshot is missing: \(path)"
            }
        }
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        undoDirectory = support
            .appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("agent-undo", isDirectory: true)
        try? FileManager.default.createDirectory(at: undoDirectory,
                                                 withIntermediateDirectories: true)
        records = DiskStore.load([AgentActionRecord].self, key: storageKey) ?? []
    }

    /// 文件写入/编辑成功后调用。`before` = 动作前内容（nil = 新文件）。
    @discardableResult
    func recordFileMutation(tool: String, path: String,
                            before: Data?, after: Data) -> AgentActionRecord {
        let id = UUID()
        var backupPath: String?
        var undoable = true
        let tooLarge = after.count > maxSnapshotBytes || (before?.count ?? 0) > maxSnapshotBytes
        if tooLarge {
            undoable = false
        } else if let before {
            let backup = undoDirectory.appendingPathComponent("\(id.uuidString).bak")
            do {
                try before.write(to: backup, options: .atomic)
                backupPath = backup.path
            } catch {
                undoable = false
                Log.agent.error("action undo snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let record = AgentActionRecord(
            id: id,
            tool: tool,
            kind: tool == "editFile" ? .fileEdit : .fileWrite,
            host: nil,
            summary: "\(tool): \(path)",
            path: path,
            backupPath: backupPath,
            existedBefore: before != nil,
            undoable: undoable,
            afterSHA256: sha256(after),
            createdAt: Date(),
            undoneAt: nil)
        insert(record)
        return record
    }

    /// 不可撤销动作（工作流运行/下载启动等）也记一条，方便审计。
    @discardableResult
    func record(tool: String, kind: AgentActionRecord.Kind,
                summary: String, host: String? = nil) -> AgentActionRecord {
        let record = AgentActionRecord(
            id: UUID(), tool: tool, kind: kind, host: host, summary: summary,
            path: nil, backupPath: nil, existedBefore: false, undoable: false,
            afterSHA256: nil, createdAt: Date(), undoneAt: nil)
        insert(record)
        return record
    }

    /// 撤销一个文件动作。先校验当前文件哈希；不匹配就拒绝，绝不覆盖用户改动。
    @discardableResult
    func undo(_ id: UUID) throws -> String {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound
        }
        var record = records[index]
        guard record.undoable, !record.isUndone, let path = record.path else {
            throw StoreError.notUndoable
        }
        let url = URL(fileURLWithPath: path)
        let current = FileManager.default.contents(atPath: path)
        if let expected = record.afterSHA256 {
            let currentHash = current.map(sha256) ?? ""
            guard currentHash == expected else { throw StoreError.fileChanged }
        }
        if record.existedBefore {
            guard let backup = record.backupPath,
                  let data = FileManager.default.contents(atPath: backup) else {
                throw StoreError.backupMissing(record.backupPath ?? "?")
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(atPath: backup)
        } else if current != nil {
            try FileManager.default.removeItem(at: url)
        }
        record.undoneAt = Date()
        records[index] = record
        save()
        return record.existedBefore ? "Restored \(path)" : "Deleted \(path)"
    }

    func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: undoDirectory)
        try? FileManager.default.createDirectory(at: undoDirectory,
                                                 withIntermediateDirectories: true)
        save()
    }

    private func insert(_ record: AgentActionRecord) {
        records.insert(record, at: 0)
        if records.count > maxRecords {
            let drop = records.suffix(from: maxRecords)
            for old in drop {
                if let backup = old.backupPath {
                    try? FileManager.default.removeItem(atPath: backup)
                }
            }
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    private func save() {
        DiskStore.save(records, key: storageKey)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
