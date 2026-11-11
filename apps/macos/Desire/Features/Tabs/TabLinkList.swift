import Foundation

/// 标签链接清单（v0.8.51 批 4）：把整排标签渲染成可分享的链接列表。
/// Foundation-only、进 tests/run.sh——剪贴板/桥/菜单共用这一个实现。
///
/// 规则：
/// - 跳过占位标签（空 URL、`about:blank`、`desire://newtab`）——复制出去是噪音；
/// - 顺序 = 标签栏顺序，不去重（同一页面开两次就是两条）；
/// - Markdown：`[标题](URL)`，标题里的 `[`/`]` 转义、换行压成空格；
///   URL 含 `)` 或空格时目标用 `<…>` 包起来（否则链接会被截断）；
/// - 纯文本：一行一个 URL（粘到下载器/地址栏可直接用）。
nonisolated enum TabLinkList {
    struct Entry: Equatable {
        let title: String
        let url: String
    }

    /// 占位/空标签不值得复制。
    static func isCopyable(url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "about:blank" { return false }
        if trimmed == "desire://newtab" { return false }
        return true
    }

    /// 过滤 + 归一化（标题为空时回退到 URL 的 host，再不行用整条 URL）。
    static func entries(_ pairs: [(title: String, url: String)]) -> [Entry] {
        pairs.compactMap { pair in
            let url = pair.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCopyable(url: url) else { return nil }
            var title = pair.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = URL(string: url)?.host ?? url
            }
            return Entry(title: title, url: url)
        }
    }

    static func render(_ entries: [Entry], markdown: Bool) -> String {
        if markdown {
            return entries.map(markdownLine).joined(separator: "\n")
        }
        return entries.map(\.url).joined(separator: "\n")
    }

    static func markdownLine(_ entry: Entry) -> String {
        let title = escapeTitle(entry.title)
        if entry.url.contains(")") || entry.url.contains(" ") {
            return "[\(title)](<\(entry.url)>)"
        }
        return "[\(title)](\(entry.url))"
    }

    /// 标题里只有方括号会破坏链接语法；换行/制表会破坏列表结构。
    static func escapeTitle(_ title: String) -> String {
        var text = title
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        text = text.replacingOccurrences(of: "[", with: "\\[")
        text = text.replacingOccurrences(of: "]", with: "\\]")
        return text
    }
}
