import Foundation

/// 「评估集管理」（v0.7.22）：把用户 👍 过的回合导出成**一行一回合的 JSONL**
/// ——评估/回归集的素材。派生口径**复用 AgentTrace**（轨迹页/桥/评估同源，
/// 不另养一份"回合是什么"的定义）；输出目录默认 `~/Documents/DesireAgent`。
///
/// 只导出、不注入：文件在用户自己的工作目录里，谁消费（agent-eval fixtures
/// / 人工复盘）由用户决定。
@MainActor
enum EvalExporter {

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("DesireAgent", isDirectory: true)
    }

    static func thumbsUpRecords(conversationStore: ConversationStore,
                                price: @escaping (String?) -> ModelPrice?) -> [[String: Any]] {
        var records: [[String: Any]] = []
        for conversation in conversationStore.conversations {
            for turn in AgentTrace.turns(of: conversation, price: price)
            where (turn["feedback"] as? String) == "up" {
                records.append([
                    "conversation": conversation.id.uuidString,
                    "title": conversation.title,
                    "goal": turn["goal"] ?? "",
                    "answer": turn["answer"] ?? "",
                    "steps": (turn["steps"] as? [[String: Any]])?
                        .compactMap { $0["action"] as? String } ?? [],
                    "startedAt": turn["startedAt"] ?? "",
                ])
            }
        }
        return records
    }

    /// 写 JSONL；返回落点与回合数（0 回合也写一个空文件——调用方据此如实提示）。
    static func export(conversationStore: ConversationStore,
                       price: @escaping (String?) -> ModelPrice?,
                       to directory: URL? = nil) throws -> (url: URL, count: Int) {
        let dir = directory ?? defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("eval-thumbsup-\(formatter.string(from: Date())).jsonl")
        let records = thumbsUpRecords(conversationStore: conversationStore, price: price)
        let lines = records.compactMap { record -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: record,
                                                         options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, records.count)
    }

    /// 已有导出（新→旧）。
    static func listExports(in directory: URL? = nil) -> [(url: URL, size: Int, modified: Date)] {
        let dir = directory ?? defaultDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("eval-thumbsup-") && $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
