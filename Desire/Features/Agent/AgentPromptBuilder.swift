import Foundation

/// Composes the agent's system prompt from ordered layers, wrapped in
/// section tags so the model can separate concerns cleanly:
///
///   <identity>    — the user's editable system prompt (persona + rules)
///   <user_memory> — L0 profile + L1 facts + L2 summaries (apply silently)
///   <skills>      — name + description list (bodies load via useSkill)
///   <workspace>   — working directory for file tools / runCommand cwd
///   <page_context>— fresh per-iteration snapshot of the current page
///
/// Every layer is omitted when empty. The composed block is injected ONCE
/// at position 0 of the request (after context compaction, so it can never
/// be dropped) and nothing is persisted into the conversation.
@MainActor
enum AgentPromptBuilder {
    struct Input {
        var identity: String          // preference.systemPrompt (or default)
        var memoryBlock: String?      // AgentMemoryStore.promptBlock
        var skills: [(name: String, description: String)]
        var workspacePath: String
        var pageContext: String?      // fresh compact page summary
    }

    static func compose(_ input: Input) -> String {
        var sections: [String] = []

        let identity = input.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            sections.append("<identity>\n\(identity)\n</identity>")
        }

        if let memory = input.memoryBlock, !memory.isEmpty {
            sections.append("<user_memory>\n\(memory)\n</user_memory>")
        }

        if !input.skills.isEmpty {
            let lines = input.skills.prefix(30)
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            sections.append("""
            <skills>
            \(lines)
            Before performing a task that matches a skill, call useSkill(name) \
            to load its full instructions.
            </skills>
            """)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        sections.append("""
        <environment>
        Working directory (file tools + runCommand cwd): \(input.workspacePath)
        Current time: \(formatter.string(from: Date()))
        </environment>
        """)

        if let page = input.pageContext, !page.isEmpty {
            sections.append("<page_context>\n\(page)\n</page_context>")
        }

        return sections.joined(separator: "\n\n")
    }
}
