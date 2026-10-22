import Foundation

/// 运营 Playbook（v0.8.2）：参数化的可运行作业定义。它不是新的执行引擎——
/// 运行时把参数与指令组合成一条 prompt 交给现有 Agent 回合；需要确定性步骤
/// 时由指令引用工作流/技能。
nonisolated struct Playbook: Identifiable, Codable, Equatable {
    struct Parameter: Identifiable, Codable, Equatable {
        var key: String
        var label: String
        var placeholder: String
        var required: Bool
        var defaultValue: String
        var choices: [String]

        var id: String { key }

        init(key: String, label: String, placeholder: String = "",
             required: Bool = true, defaultValue: String = "",
             choices: [String] = []) {
            self.key = key
            self.label = label
            self.placeholder = placeholder
            self.required = required
            self.defaultValue = defaultValue
            self.choices = choices
        }
    }

    enum Output: String, Codable, CaseIterable {
        case chat
        case file
        case note

        var label: String {
            switch self {
            case .chat: String(localized: "Answer in chat")
            case .file: String(localized: "Write a file and give the path")
            case .note: String(localized: "Add a note to the conversation")
            }
        }
    }

    let id: UUID
    var name: String
    var summary: String
    /// 给 Agent 的完整指令（可引用技能/工作流/工具）。
    var instructions: String
    var parameters: [Parameter]
    /// 可选：先 useSkill 加载这个技能。
    var skillName: String?
    var output: Output
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, summary: String = "",
         instructions: String, parameters: [Parameter] = [],
         skillName: String? = nil, output: Output = .chat,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.parameters = parameters
        self.skillName = skillName
        self.output = output
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Playbook 运行前的校验与 prompt 组合（纯逻辑，进 harness）。
nonisolated enum PlaybookRun {
    static func missingRequired(_ playbook: Playbook,
                                values: [String: String]) -> [Playbook.Parameter] {
        playbook.parameters.filter { parameter in
            guard parameter.required else { return false }
            let value = (values[parameter.key] ?? parameter.defaultValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty
        }
    }

    static func compose(_ playbook: Playbook,
                        values: [String: String]) -> String {
        var lines = ["Run this playbook: \(playbook.name)"]
        if !playbook.summary.isEmpty { lines.append(playbook.summary) }
        if let skill = playbook.skillName, !skill.isEmpty {
            lines.append("First load the skill \"\(skill)\" with useSkill, then follow this playbook.")
        }
        lines.append("")
        if !playbook.instructions.isEmpty {
            lines.append("Instructions:")
            lines.append(playbook.instructions)
            lines.append("")
        }
        if !playbook.parameters.isEmpty {
            lines.append("Parameters:")
            for parameter in playbook.parameters {
                let raw = values[parameter.key] ?? parameter.defaultValue
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("- \(parameter.key) (\(parameter.label)): \(value.isEmpty ? "(not provided)" : value)")
            }
            lines.append("")
        }
        lines.append("Rules:")
        lines.append("- Use the provided parameters; if a required fact is missing, ask instead of inventing it.")
        lines.append("- Never publish, send, submit or purchase anything without explicit user approval.")
        lines.append("- Work with current browser tools; report what you actually did and any blockers.")
        switch playbook.output {
        case .chat:
            lines.append("- Return the result in the chat with sources/links where applicable.")
        case .file:
            lines.append("- Write the result to a file in the workspace and give the full path.")
        case .note:
            lines.append("- Save the result as a conversation note and summarize it in the chat.")
        }
        return lines.joined(separator: "\n")
    }
}
