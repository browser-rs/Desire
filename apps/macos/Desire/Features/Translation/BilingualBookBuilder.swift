import Foundation

/// **双语成书 HTML 组装**（v0.8.64 批 2，Foundation-only 进 tests/run.sh）：
/// 把页面侧收集到的 (原文, 译文) 对组装成一篇对照 HTML——交给
/// `EbookWebBookImporter.importArticle` 落书架（HTML 离线书，阅读器/
/// 全库搜索/EPUB 导出全部既有能力直接受益）。
///
/// 转义口径与 0.8.62 页面侧 apply 一致：原文/译文**整段 HTML 转义**后才
/// 进文档——页面内容不能诱导注入（原文来自任意网页，是不可信输入）。
nonisolated enum BilingualBookBuilder {

    struct Pair {
        let original: String
        let translation: String
    }

    /// 最小 HTML 转义（& 优先，防二次转义）。
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 对照文档：标题 + 每对两段（.orig 原文 / .bi 译文）。译文在原文本
    /// 之后，阅读器里即"读一句、看一句"的自然顺序。
    static func buildHTML(title: String, pairs: [Pair]) -> String {
        var parts: [String] = []
        parts.append("<h1>\(escape(title))</h1>")
        for pair in pairs {
            parts.append("<div class=\"pair\">")
            parts.append("<p class=\"orig\">\(escape(pair.original))</p>")
            parts.append("<p class=\"bi\">\(escape(pair.translation))</p>")
            parts.append("</div>")
        }
        return "<article>\n" + parts.joined(separator: "\n") + "\n</article>"
    }

    /// 书名：用户页面标题为骨，"Bilingual · " 前缀标明来源。插值键要手工
    /// 转目录格式串——这里用固定前缀键拼接，免维护 %@ 格式串。
    static func bookTitle(pageTitle: String, host: String) -> String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? host : trimmed
        return String(localized: "Bilingual") + " · " + base
    }
}
