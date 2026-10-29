import Foundation
import os

/// 知识周报（v0.8.22）：把本周新增的摘录按语义聚成 3–6 个主题，落一份
/// Markdown 到 Agent 工作目录，并发一条 routine 通知。**确定性优先**：
/// 聚类只用端上向量 + 贪心（同输入同输出），不调模型。
///
/// 跨语言口径：中文/英文向量空间不同，先按语言分组各自聚类再合并
/// （跨空间余弦没有意义）。
@MainActor
enum KnowledgeWeeklyDigest {
    struct Outcome: Sendable {
        var path: String
        var items: Int
        var themes: Int
        var skipped: Int
    }

    static func run(days: Int = 7, directory: URL? = nil) async -> Outcome? {
        let span = Double(max(1, days)) * 86_400
        let since = Date().addingTimeInterval(-span)
        let items = KnowledgeDigestCore.pickRecent(
            ExcerptStore.shared.excerpts.map { excerpt in
                KnowledgeDigestCore.Item(
                    id: excerpt.id.uuidString,
                    title: excerpt.title.isEmpty ? String(excerpt.content.prefix(60)) : excerpt.title,
                    text: excerpt.content,
                    kind: excerpt.kindLabel,
                    date: excerpt.createdAt)
            },
            since: since)
        guard !items.isEmpty else { return nil }

        var clusters: [[String]] = []
        var skipped = 0
        let grouped = Dictionary(grouping: items) { item in
            SemanticText.detectLanguage(item.title + " " + item.text)
        }
        for (language, group) in grouped {
            var vectors: [SemanticClusterCore.VectorItem] = []
            for item in group {
                guard let output = SemanticEmbedder.embed(
                    SemanticText.embedInput(title: item.title, body: item.text),
                    language: language) else {
                    skipped += 1
                    continue
                }
                vectors.append(.init(id: item.id, vector: output.vector))
            }
            clusters.append(contentsOf: SemanticClusterCore.cluster(vectors))
        }

        let markdown = KnowledgeDigestCore.markdown(items: items, clusters: clusters,
                                                     since: since, until: Date())
        let target = directory ?? AgentWorkspace.shared.directory
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            let url = target.appendingPathComponent(
                "knowledge-weekly-\(formatter.string(from: Date())).md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Weekly knowledge digest ready"),
                body: String(localized: "\(items.count) excerpt(s) grouped into \(max(1, clusters.count)) theme(s)."),
                tier: .routine)
            Log.agent.info("knowledge digest: \(items.count, privacy: .public) items, \(clusters.count, privacy: .public) themes, \(skipped, privacy: .public) skipped")
            return Outcome(path: url.path, items: items.count,
                           themes: max(1, clusters.count), skipped: skipped)
        } catch {
            Log.agent.error("knowledge digest write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
