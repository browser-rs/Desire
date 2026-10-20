import Foundation

/// 评估 fixture 的格式桥（v0.7.27）：应用导出的是**一行一回合的 JSONL**，
/// `tests/agent-eval.py --fixtures` 吃的是 `{fixtures:[{goal,answer,title}]}`。
/// 纯逻辑（Foundation-only，进 harness）——应用内"登记为 fixture"与 CLI 同格式。
nonisolated enum EvalFixture {
    struct Entry: Codable, Equatable {
        var goal: String
        var answer: String
        var title: String
    }

    struct File: Codable, Equatable {
        var warning: String
        var exportedAt: String
        var count: Int
        var fixtures: [Entry]
    }

    static let warning = "Contains real conversation content — do NOT commit this file."

    /// 把应用导出的 JSONL 转成 fixture 文件对象。
    /// - 跳过空行 / 坏 JSON / 空 goal；同 goal 去重（先到先得）。
    /// - 截断口径与 CLI 一致（goal 500 / answer 2000）。
    /// - 不在这里脱敏（调用方在应用层用 SecretRedactor 处理，保持本文件零依赖）。
    static func convert(jsonl: String, exportedAt: String, limit: Int = 50) -> File {
        var seen = Set<String>()
        var entries: [Entry] = []
        for rawLine in jsonl.split(whereSeparator: \.isNewline) {
            guard entries.count < limit else { break }
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawGoal = object["goal"] as? String else { continue }
            let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty, !seen.contains(goal) else { continue }
            seen.insert(goal)
            entries.append(Entry(goal: String(goal.prefix(500)),
                                 answer: String((object["answer"] as? String ?? "").prefix(2000)),
                                 title: object["title"] as? String ?? ""))
        }
        return File(warning: warning, exportedAt: exportedAt,
                    count: entries.count, fixtures: entries)
    }

    static func encode(_ file: File) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(file)
    }

    static func parse(_ data: Data) -> File? {
        try? JSONDecoder().decode(File.self, from: data)
    }
}
