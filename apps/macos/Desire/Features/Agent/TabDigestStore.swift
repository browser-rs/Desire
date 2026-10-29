import Combine
import Foundation
import os

/// 跨标签上下文（v0.8.22 批三）：把"当前窗口的标签页"变成 Agent 能用的两种
/// 产物——
/// - `startDigest`：后台逐页取文 → 一次旁路模型摘要（逐页 1-2 句 + 总览），
///   完成后写会话备注 + 系统通知；长任务模式（立刻返回，不阻塞回合）。
/// - `ask`：读文 → 带问题的一次旁路模型调用 → 答案带 `[n]` 来源编号。
///
/// 取文复用 `URLReader`：**已打开的标签直接借它的 webview**（登录态生效、
/// 零等待），没打开的才离屏加载。总上下文封顶 4 万字符，超了截断并标注。
@MainActor
final class TabDigestStore: ObservableObject {
    static let shared = TabDigestStore()

    struct Snapshot: Sendable {
        var tabCount: Int
        var digest: String
        var sources: [String]
        var createdAt: Date
    }

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var last: Snapshot?

    private init() {}

    /// 开始后台摘要；返回排队的标签数（0 = 没有可读标签或已有任务在跑）。
    @discardableResult
    func startDigest(urls: [String], maxCharsPerTab: Int,
                     preference: AgentPreferenceStore,
                     session: AgentSessionStore?) -> Int {
        guard !isRunning else { return 0 }
        let targets = Array(urls.prefix(12))
        guard !targets.isEmpty else { return 0 }
        isRunning = true
        total = targets.count
        done = 0
        Task { [weak self] in
            guard let self else { return }
            var entries: [(title: String, url: String, text: String)] = []
            for url in targets {
                if let read = await URLReader.read(url: url,
                                                   maxChars: max(500, maxCharsPerTab),
                                                   includeLinks: false) {
                    let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count > 40 {
                        entries.append((read.title.isEmpty ? url : read.title, url, text))
                    }
                }
                self.done += 1
            }
            guard !entries.isEmpty else {
                self.isRunning = false
                session?.appendExternalNote(
                    "标签页摘要失败：没有取到可读正文（页面可能未加载、需要登录，或只有视频/画布）。")
                return
            }
            let block = Self.capped(Self.context(from: entries))
            let summary = await MemoryExtractor.collectText(
                preference: preference,
                system: "你是标签页整理助手。用户当前窗口打开了若干标签页，下面是它们的正文（带 [n] 编号）。逐页用 1-2 句说明它讲什么，最后给一段总览（主题分组、共同点或互相矛盾之处）。引用页面时用 [n]。只输出正文，不加前后缀。",
                user: block,
                onUsage: { prompt, completion, model in
                    AgentSessionStore.recordBypassUsage(kind: "tabDigest", prompt: prompt,
                                                        completion: completion, model: model)
                })
            let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            self.isRunning = false
            guard !cleaned.isEmpty else {
                session?.appendExternalNote("标签页摘要失败：模型没有返回内容，可以稍后重试。")
                return
            }
            self.last = Snapshot(tabCount: entries.count, digest: cleaned,
                                 sources: entries.map(\.url), createdAt: Date())
            session?.appendExternalNote("当前窗口 \(entries.count) 个标签页的摘要：\n\n" + cleaned)
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Tab summary ready"),
                body: String(localized: "Summarized \(entries.count) open tab(s) — the digest is in the session note."),
                tier: .routine)
            Log.agent.info("tab digest done — \(entries.count, privacy: .public) tab(s)")
        }
        return targets.count
    }

    /// 带问题的一次性问答；失败（无可读正文/模型空返回）为 nil。
    func ask(question: String, urls: [String], maxCharsPerTab: Int, maxTabs: Int,
             preference: AgentPreferenceStore) async -> (answer: String, sources: [String])? {
        let entries = await Self.read(urls: urls, maxCharsPerTab: maxCharsPerTab, maxTabs: maxTabs)
        guard !entries.isEmpty else { return nil }
        let block = Self.capped(Self.context(from: entries))
        let answer = await MemoryExtractor.collectText(
            preference: preference,
            system: "你是浏览助手。用户会问一个关于他打开的这些标签页的问题。只依据给定内容回答；引用来源用 [n]。内容不足以回答就直接说缺什么，不要编造。",
            user: "问题：\(question)\n\n标签页内容：\n\(block)",
            onUsage: { prompt, completion, model in
                AgentSessionStore.recordBypassUsage(kind: "tabsAsk", prompt: prompt,
                                                    completion: completion, model: model)
            })
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return (cleaned, entries.map(\.url))
    }

    // MARK: - 取文与上下文

    static func read(urls: [String], maxCharsPerTab: Int, maxTabs: Int)
        async -> [(title: String, url: String, text: String)] {
        var out: [(title: String, url: String, text: String)] = []
        for url in urls.prefix(max(1, maxTabs)) {
            guard let read = await URLReader.read(url: url,
                                                  maxChars: max(500, maxCharsPerTab),
                                                  includeLinks: false) else { continue }
            let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 40 else { continue }
            out.append((read.title.isEmpty ? url : read.title, url, text))
        }
        return out
    }

    /// 编号/拼装/封顶在 TabDigestCore（Foundation-only，进 harness）。
    static func context(from entries: [(title: String, url: String, text: String)]) -> String {
        TabDigestCore.context(from: entries.map {
            TabDigestCore.Entry(title: $0.title, url: $0.url, text: $0.text)
        })
    }

    static func capped(_ block: String) -> String {
        TabDigestCore.capped(block)
    }
}
