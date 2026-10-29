import Combine
import Foundation
import os

/// 阅读列表批量摘要（v0.7.19）：把「读完这 N 篇给我一份汇总」变成后台流水线——
/// 逐条 **readURL 取正文**（已开标签复用含登录态；否则离屏加载）→ 一次**旁路
/// 模型摘要**（MemoryExtractor.collectText 同管道，当前档案口径）→ 写回条目
/// （`ReadingListItem.summary`，盖 LWW 戳随云同步走）。
///
/// **长任务模式**（同 MediaExportStore：别让工具 await 到底）：调用方（工具/桥）
/// 立刻拿到"已开跑 N 条"，逐条写完 store（面板实时可见），收尾发系统通知 +
/// 会话备注（绑定了会话时）。
@MainActor
final class ReadingListSummarizer: ObservableObject {
    static let shared = ReadingListSummarizer()

    @Published private(set) var isRunning = false
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var currentTitle: String?

    private init() {}

    /// 立刻返回待处理条数（0 = 没有可摘要的/已有任务在跑）；工作在后台 Task。
    /// `urls` 非空 = 只摘要这些 URL（E2E/按条触发用——绝不误动列表里其它条目）。
    @discardableResult
    func start(store: ReadingListStore,
               preference: AgentPreferenceStore,
               limit: Int,
               force: Bool,
               urls: [String] = [],
               session: AgentSessionStore?) -> Int {
        guard !isRunning else { return 0 }
        let wanted = Set(urls)
        let targets = Array(store.items
            .filter { wanted.isEmpty || wanted.contains($0.url) }
            .filter { force || ($0.summary ?? "").isEmpty }
            .prefix(max(1, limit)))
        guard !targets.isEmpty else { return 0 }
        isRunning = true
        totalCount = targets.count
        completedCount = 0
        failedCount = 0
        Task { [weak self] in
            guard let self else { return }
            var made = 0
            for item in targets {
                self.currentTitle = item.title
                if await Self.summarizeOne(item: item, store: store, preference: preference) {
                    made += 1
                    self.completedCount += 1
                } else {
                    self.failedCount += 1
                }
            }
            self.currentTitle = nil
            let done = self.completedCount
            let failed = self.failedCount
            self.isRunning = false
            guard made > 0 else { return }
            session?.appendExternalNote(
                "阅读列表摘要完成：\(done) 篇（失败 \(failed)）。摘要已随条目保存并同步。")
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Reading summaries ready"),
                body: String(localized: "Summarized \(done) saved page(s) — open the Reading List to read them."),
                tier: .routine)
        }
        return targets.count
    }

    /// 摘一篇：readURL 取正文 → 旁路模型 2-3 句摘要 → 写回。失败（离线/超时/
    /// 空稿）返回 false——**不写任何标记**，下一轮自然重试。
    private static func summarizeOne(item: ReadingListItem,
                                     store: ReadingListStore,
                                     preference: AgentPreferenceStore) async -> Bool {
        guard let read = await URLReader.read(url: item.url, maxChars: 12_000, includeLinks: false) else {
            Log.agent.info("reading summary: read failed for \(item.url, privacy: .public)")
            return false
        }
        let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 40 else { return false }
        // 阅读列表正文补进历史正文索引（v0.8.22）：摘要链路本来就把正文读出来了，
        // 顺手喂给（opt-in 的）历史正文索引，让"读过的长文"也能被语义/字面检索到。
        HistoryContentStore.shared.capture(url: item.url,
                                           title: read.title.isEmpty ? item.title : read.title,
                                           text: text,
                                           isPrivate: false)
        let head = read.title.isEmpty ? item.title : read.title
        let summary = await MemoryExtractor.collectText(
            preference: preference,
            system: "你是阅读助理。用 2-3 句话给这篇网页写摘要：先一句主旨，再 1-2 句关键要点。只输出摘要本身，不加前后缀、不加引号。",
            user: "标题：\(head)\n\n正文：\n\(text)",
            onUsage: { p, c, m in
                AgentSessionStore.recordBypassUsage(kind: "readingList", prompt: p,
                                                    completion: c, model: m)
            })
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        store.setSummary(item.id, text: String(cleaned.prefix(600)))
        return true
    }
}
