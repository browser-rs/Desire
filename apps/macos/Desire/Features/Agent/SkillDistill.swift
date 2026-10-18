import Foundation

/// 「从会话提炼技能」的**纯逻辑**（v0.7.22 旗舰；Foundation-only 进 harness）：
/// ① 会话 → 给模型的运行记录（transcript）；② 模型输出 → 技能草稿（容错解析）。
/// 编辑器预填与桥 `/skills/distill` 共用——形状只有一处。
nonisolated enum SkillDistill {

    struct Draft: Equatable {
        let name: String
        let description: String
        let instructions: String
    }

    /// 容忍代码围栏/前后杂谈的 JSON 草稿解析；必填缺失或空正文 → nil。
    /// 名称截 60 字符、描述压成单行截 160（frontmatter 约束）；正文若自带
    /// frontmatter 剥掉一层（编辑器保存时由 SkillAuthoring 重新生成权威头）。
    static func draft(fromModelOutput raw: String) -> Draft? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let name = (object["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (object["description"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var instructions = (object["instructions"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty, !instructions.isEmpty else { return nil }
        if instructions.hasPrefix("---"), let end = instructions.range(of: "\n---") {
            instructions = String(instructions[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !instructions.isEmpty else { return nil }
        let singleLine = description
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Draft(
            name: String(name.prefix(60)),
            description: String(singleLine.prefix(160)),
            instructions: instructions
        )
    }

    /// 会话 → 运行记录（保留**尾部** maxChars 字符——最近干的事才是技能
    /// 素材；前端溢出加省略标记）。跳过 system；每条按角色压缩成单行、
    /// 工具调用与结果截断（token 预算留在调用点一侧）。
    static func transcript(from messages: [AgentMessage], maxChars: Int = 12_000) -> String {
        var lines: [String] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                lines.append("USER: " + compact(message.content ?? "", limit: 1200))
            case .assistant:
                var line = "ASSISTANT: " + compact(message.content ?? "", limit: 1200)
                for call in message.toolCalls ?? [] {
                    line += "\n  [tool] \(call.function.name) " +
                        compact(call.function.arguments, limit: 300)
                }
                lines.append(line)
            case .tool:
                lines.append("  [result] " + compact(message.content ?? "", limit: 600))
            }
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        if joined.count > maxChars {
            return "…(前文截断)\n" + String(joined.suffix(maxChars))
        }
        return joined
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let singleLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit)) + "…" : singleLine
    }
}
