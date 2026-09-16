import Foundation
import os

/// Turns raw conversation turns into layered memory: L1 durable facts and
/// L2 conversation summaries. Runs in the background after agent turns —
/// never blocks the interactive loop. Extraction uses the SAME provider
/// chain as the agent (respecting Auto routing), with no tools offered.
@MainActor
enum MemoryExtractor {
    private static let log = Log.ai

    // MARK: - L1: fact extraction

    /// Extracts durable USER facts (preferences, habits, corrections) from
    /// the conversation tail and merges them into the memory store.
    static func extractFacts(
        preference: AgentPreferenceStore,
        memory: AgentMemoryStore,
        messages: [AgentMessage]
    ) async {
        guard preference.memoryLearning else { return }
        let transcript = transcript(of: messages, maxChars: 6000)
        guard !transcript.isEmpty else { return }

        let existing = memory.archive.facts.map(\.content).joined(separator: "\n- ")
        let system = """
        You are the memory subsystem of a browser agent. Extract DURABLE facts \
        about the USER (never page content, never one-off task state) from the \
        conversation. Reply with STRICT JSON only, no prose:
        {"facts":[{"content":"...","category":"preference|habit|fact|correction"}],\
        "profile":{"name":"","language":"","style":"","custom":""}}
        Rules: at most 5 facts; only lasting user traits (sites they frequent, \
        preferred reply style, language, how they want tasks done); skip \
        anything already in the existing list; use empty arrays/strings when \
        nothing new.
        """
        let user = """
        Existing facts:
        - \(existing.isEmpty ? "(none)" : existing)

        Conversation:
        \(transcript)
        """

        let text = await collectText(preference: preference, system: system, user: user)
        guard let data = jsonPayload(from: text),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("memory extraction: no parseable JSON returned")
            return
        }

        if let facts = obj["facts"] as? [[String: Any]] {
            for fact in facts.prefix(5) {
                guard let content = fact["content"] as? String, !content.isEmpty else { continue }
                memory.addFact(
                    content: String(content.prefix(200)),
                    category: fact["category"] as? String ?? "fact"
                )
            }
        }
        if let profile = obj["profile"] as? [String: Any] {
            memory.updateProfile { p in
                if let v = profile["name"] as? String, !v.isEmpty { p.name = String(v.prefix(60)) }
                if let v = profile["language"] as? String, !v.isEmpty { p.language = String(v.prefix(40)) }
                if let v = profile["style"] as? String, !v.isEmpty { p.style = String(v.prefix(60)) }
                if let v = profile["custom"] as? String, !v.isEmpty { p.customInstructions = String(v.prefix(500)) }
            }
        }
    }

    // MARK: - L2: conversation summary

    /// Digests a conversation into a short summary stored under its id, so
    /// future sessions can recall it without the raw transcript.
    static func summarize(
        preference: AgentPreferenceStore,
        memory: AgentMemoryStore,
        conversationId: UUID,
        messages: [AgentMessage]
    ) async {
        guard preference.memoryLearning else { return }
        let transcript = transcript(of: messages, maxChars: 8000)
        guard !transcript.isEmpty else { return }

        let system = """
        Summarize this browser-agent conversation for long-term recall in at \
        most 80 words: what the user wanted, the key outcome, and any durable \
        preferences observed. Plain text only, no preamble.
        """
        let text = await collectText(
            preference: preference,
            system: system,
            user: transcript
        )
        memory.upsertSummary(conversationId: conversationId, summary: String(text.prefix(600)))
    }

    // MARK: - Plumbing

    private static func transcript(of messages: [AgentMessage], maxChars: Int) -> String {
        var lines: [String] = []
        for message in messages where message.role == .user || message.role == .assistant {
            guard var content = message.content, !content.isEmpty else { continue }
            if !(message.imageDataURIs ?? []).isEmpty {
                content = "[image attached] " + content
            }
            let role = message.role == .user ? "USER" : "ASSISTANT"
            lines.append("\(role): \(content)")
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxChars {
            text = "…[earlier omitted]\n" + text.suffix(maxChars)
        }
        return text
    }

    private static func collectText(
        preference: AgentPreferenceStore, system: String, user: String
    ) async -> String {
        var output = ""
        let messages = [
            AgentMessage(role: .system, content: system),
            AgentMessage(role: .user, content: user),
        ]
        let provider = preference.provider
        do {
            for try await event in provider.stream(messages: messages, tools: [], prefs: preference) {
                if case .text(let delta) = event { output += delta }
            }
        } catch {
            log.debug("memory call failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return output
    }

    /// Pulls the first {...} JSON object out of a possibly chatty reply.
    private static func jsonPayload(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return Data(String(text[start...end]).utf8)
    }
}
