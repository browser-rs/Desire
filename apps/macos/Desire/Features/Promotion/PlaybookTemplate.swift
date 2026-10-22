import Foundation

/// Playbook 模板（v0.8.2）：首次使用时的运营起手式。用户可删除/修改；
/// 模板本身不执行任何动作，只是参数化 prompt 的骨架。
nonisolated enum PlaybookTemplate {
    static func all(version: String) -> [Playbook] {
        let current = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            releaseCampaign(version: current),
            weeklyReview(),
            replyToMention(),
            pageBrief(),
        ]
    }

    static func releaseCampaign(version: String) -> Playbook {
        Playbook(
            name: "Release campaign",
            summary: "Turn a release's factual highlights into per-channel drafts.",
            instructions: """
            Read the actual CHANGELOG/release notes (ask the user for the version's facts if not available) and create a campaign with the promotionCampaign tool. Use only factual highlights — no invented features, no "best/first" claims. Then list the generated drafts by channel and flag which facts still need verification. Do not publish.
            """,
            parameters: [
                .init(key: "version", label: "Version", placeholder: "0.8.2", defaultValue: version),
                .init(key: "highlights", label: "Highlights", placeholder: "One factual highlight per line", required: true),
                .init(key: "channels", label: "Channels", placeholder: "X, 小红书, V2EX", defaultValue: "X, 小红书, V2EX"),
            ],
            output: .chat)
    }

    static func weeklyReview() -> Playbook {
        Playbook(
            name: "Weekly operations review",
            summary: "Collect metrics, compare growth, distil lessons and propose next actions.",
            instructions: """
            Use promotionBrief and promotionReport first. Visit the configured accounts/posts to refresh numbers with promotionAccountMetrics/promotionMetrics (only for data you can actually read). Summarize what worked/failed, record reusable lessons via promotionLesson, and propose next week's concrete actions (channels, topics, timing). Clearly mark missing data instead of guessing. Do not publish or reply.
            """,
            parameters: [
                .init(key: "period", label: "Period", placeholder: "last 7 days", required: false, defaultValue: "last 7 days"),
            ],
            output: .chat)
    }

    static func replyToMention() -> Playbook {
        Playbook(
            name: "Reply to a mention",
            summary: "Draft a platform-appropriate reply and wait for approval before posting.",
            instructions: """
            Open the mention URL and read the surrounding thread so the reply fits the context. Draft a short, specific, non-defensive reply in the requested tone. Check the draft with the user and get explicit approval. Only after approval, use the site's UI to post it, then record the interaction as replied and show the posted URL. If anything about the context is unclear, ask instead of posting.
            """,
            parameters: [
                .init(key: "url", label: "Mention URL", placeholder: "https://…", required: true),
                .init(key: "tone", label: "Tone", placeholder: "friendly / technical / concise", defaultValue: "friendly", choices: ["friendly", "technical", "concise"]),
            ],
            output: .chat)
    }

    static func pageBrief() -> Playbook {
        Playbook(
            name: "Page brief with citations",
            summary: "Research the current page and related local sources, then answer with [n] citations.",
            instructions: """
            Use researchSources (and readURL for direct pages) to collect relevant local sources. Answer the user's focus question with numbered [n] citations, quoting short snippets. If the sources don't support a claim, say so instead of inventing it.
            """,
            parameters: [
                .init(key: "focus", label: "Focus", placeholder: "What should the brief answer?", required: true),
            ],
            output: .chat)
    }
}
