import Foundation

/// **翻译术语表**（v0.8.64 批 1）：用户显式维护的"原文 → 固定译法"对照表，
/// 双语翻译时并入 system 的 Glossary 段——专有名词/产品名/人名不再被机翻
/// 弄坏。与 v0.8.8 的记忆通道（`category=translation` 的记忆事实，自由文本）
/// 并存：本表是结构化维护入口，注入时**专用表在前、记忆行在后**。
///
/// 两级作用域：`host == nil` 全局生效；`host = "example.com"` 只在该站
/// （含子域）生效。判定纯逻辑进 tests/run.sh；持久化走 DiskStore
/// （key `translation-glossary`，500ms 防抖异步写，同 DiskStore 语义）。
nonisolated enum TranslationGlossary {

    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        /// 原文术语（按短语的字面形态进提示词，不做大小写折叠——专有名
        /// 词的大小写本身就是信息）。
        var term: String
        /// 固定译法。
        var translation: String
        /// 作用域 host（nil = 全局；存小写）。
        var host: String?
    }

    /// 清洗：去空白项、trim、host 小写、同 (term, host) 去重保留最后一条
    /// （编辑器逐行保存时后写覆盖先写，符合"最后一次编辑为准"直觉）。
    static func normalized(_ entries: [Entry]) -> [Entry] {
        var seen: [String: Int] = [:]
        var out: [Entry] = []
        for var entry in entries {
            entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.translation = entry.translation
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let host = entry.host {
                let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                entry.host = trimmed.isEmpty ? nil : trimmed
            }
            guard !entry.term.isEmpty, !entry.translation.isEmpty else { continue }
            let key = entry.term.lowercased() + "\u{1f}" + (entry.host ?? "")
            if let idx = seen[key] {
                out[idx] = entry
            } else {
                seen[key] = out.count
                out.append(entry)
            }
        }
        return out
    }

    /// host 匹配：nil host 条目全局生效；条目 host 与页面 host 相等，或页面
    /// host 以 "." + 条目 host 结尾（子域）。host 参数为 nil/空 = 只取全局。
    static func matches(_ entryHost: String?, pageHost: String?) -> Bool {
        guard let entryHost, !entryHost.isEmpty else { return true }
        guard let pageHost, !pageHost.isEmpty else { return false }
        let host = pageHost.lowercased()
        return host == entryHost || host.hasSuffix("." + entryHost)
    }

    /// 生效条目：按 host 过滤，**长 term 优先**（防短词先把长词的片段
    /// 换掉——提示词层面模型自主取用，顺序是软引导）。
    static func effectiveEntries(_ entries: [Entry], host: String?) -> [Entry] {
        normalized(entries)
            .filter { matches($0.host, pageHost: host) }
            .sorted { $0.term.count != $1.term.count
                ? $0.term.count > $1.term.count
                : $0.term < $1.term }
    }

    /// Glossary 段的行格式（与记忆行同段注入："term → translation"）。
    static func lines(_ entries: [Entry], host: String?) -> [String] {
        effectiveEntries(entries, host: host).map { "\($0.term) → \($0.translation)" }
    }
}
