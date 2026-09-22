import Foundation

/// Composes the agent's system prompt from ordered layers, wrapped in
/// section tags so the model can separate concerns cleanly:
///
///   <identity>    — the user's editable system prompt (persona + rules)
///   <user_memory> — L0 profile + L1 facts + L2 summaries (apply silently)
///   <skills>      — name + description list (bodies load via useSkill)
///   <tools>       — GENERATED index of every callable tool (name + one line)
///   <environment> — working/downloads dirs, tooling, current time
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
        /// 工具索引（由 `BrowserToolProvider.promptInventory` 生成，含 MCP 工具）。
        /// 手写索引会随工具增删漂移——实测漏了 76/106 个，所以改成生成。
        var tools: [(name: String, summary: String)] = []
        var workspacePath: String
        var downloadsPath: String?
        /// 装了 ffmpeg 就直连 HLS 出 MP4，没装则回退内置下载器（产物可能是 .ts）。
        var ffmpegAvailable: Bool = false
        var ffmpegPath: String?
        var pageContext: String?      // fresh compact page summary
    }

    /// Downloads 目录（`downloadMedia` / `stopRecording` 的落点）。
    static var downloadsPath: String? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
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

        if !input.tools.isEmpty {
            let lines = input.tools
                .map { "- \($0.name) — \($0.summary)" }
                .joined(separator: "\n")
            sections.append("""
            <tools>
            Every tool below is callable; the request's `tools` parameter is \
            authoritative for parameters and exact semantics. Use this index for \
            routing (the descriptions here are one-line summaries).
            \(lines)
            </tools>
            """)
        }

        var environment = ["Working directory (file tools + runCommand cwd): \(input.workspacePath)"]
        if let downloads = input.downloadsPath {
            environment.append("Downloads folder (downloadMedia / stopRecording write here): \(downloads)")
        }
        if input.ffmpegAvailable {
            let where_ = input.ffmpegPath.map { " (\($0))" } ?? ""
            environment.append("ffmpeg\(where_): available — HLS/video exports are remuxed straight to MP4")
        } else {
            environment.append("ffmpeg: not installed — HLS exports fall back to the built-in downloader and may land as .ts; suggest `runCommand brew install ffmpeg` when the user needs MP4")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        environment.append("Current time: \(formatter.string(from: Date()))")
        sections.append("<environment>\n\(environment.joined(separator: "\n"))\n</environment>")

        if let page = input.pageContext, !page.isEmpty {
            sections.append("<page_context>\n\(page)\n</page_context>")
        }

        return sections.joined(separator: "\n\n")
    }
}
