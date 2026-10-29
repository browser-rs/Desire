import Foundation

/// 输入框 `@` 引用的标签页（v0.8.22）：发送时把正文读出来，作为本轮的系统
/// 备注（`## Referenced tabs` 段）注入——不进聊天记录、不污染用户输入，
/// 模型在下一轮请求的系统提示词里就能看到。
nonisolated struct AgentTabReference: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var url: String
}

@MainActor
enum AgentTabReferenceInjector {
    /// 逐条读取引用标签的正文（已开标签直接借 webview，登录态生效），
    /// 拼成一段系统备注追加到会话。读不到正文时如实标注，不静默丢。
    static func appendNote(_ refs: [AgentTabReference],
                           to session: AgentSessionStore,
                           maxCharsPerTab: Int = 6_000) async {
        guard !refs.isEmpty else { return }
        var blocks: [String] = ["## Referenced tabs (user explicitly attached this turn)"]
        for (index, ref) in refs.enumerated() {
            var text = ""
            if let read = await URLReader.read(url: ref.url,
                                               maxChars: maxCharsPerTab,
                                               includeLinks: false) {
                text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.isEmpty {
                text = "(body unavailable — page may not be loaded or may need login)"
            }
            blocks.append("[\(index + 1)] \(ref.title)\n\(ref.url)\n\(text)")
        }
        session.appendExternalNote(blocks.joined(separator: "\n\n"))
    }
}
