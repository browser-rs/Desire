import Foundation

/// OPML 导入/导出（v0.8.45 丰富批）：订阅清单的通用交换格式。
/// Foundation-only，进 tests/run.sh。导入 = outline[type="rss"|"atom"] 的
/// xmlUrl 属性（嵌套 outline 的 text 当分组名）；导出 = 单层（分组用
/// outline text 包裹），xml/html 属性做 XML 转义。
nonisolated enum FeedOPMLCore {

    struct Entry: Equatable, Sendable {
        var title: String
        var url: String
        var siteURL: String?
        var collection: String?
    }

    // MARK: - 导出

    static func export(feeds: [Feed]) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\">")
        lines.append("  <head><title>Desire subscriptions</title></head>")
        lines.append("  <body>")
        // 按分组归并：nil 分组直接单层 outline；有分组的进容器
        let grouped = Dictionary(grouping: feeds) { $0.collectionName ?? "" }
        for (collection, items) in grouped.sorted(by: { $0.key < $1.key }) {
            let escapedName = escape(collection.isEmpty ? "Subscriptions" : collection)
            let inner = collection.isEmpty
            if !inner {
                lines.append("    <outline text=\"\(escapedName)\">")
            }
            for feed in items.sorted(by: { $0.title < $1.title }) {
                var attrs = "text=\"\(escape(feed.title))\" type=\"rss\" xmlUrl=\"\(escape(feed.url))\""
                if let site = feed.siteURL {
                    attrs += " htmlUrl=\"\(escape(site))\""
                }
                lines.append(inner
                    ? "    <outline \(attrs)/>"
                    : "      <outline \(attrs)/>")
            }
            if !inner {
                lines.append("    </outline>")
            }
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    // MARK: - 导入

    /// 解析 OPML；无 xmlUrl 条目返回空数组（不判失败——空订阅清单合法）。
    /// 非法 XML 返回 nil。
    static func importEntries(from data: Data) -> [Entry]? {
        let delegate = OPMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.entries
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// XMLParser 委托：只认 outline 元素的属性与嵌套容器。nonisolated（回调同步）。
/// 嵌套配对：每个 outline 都入栈（nil = 叶子条目，非 nil = 分组容器），
/// 结束时对称出栈——否则"条目 outline 自闭合"会误弹分组。
private nonisolated final class OPMLDelegate: NSObject, XMLParserDelegate {
    private var stack: [String?] = []
    private(set) var entries: [FeedOPMLCore.Entry] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }
        if let xmlURL = attributeDict["xmlUrl"], !xmlURL.isEmpty {
            entries.append(FeedOPMLCore.Entry(
                title: attributeDict["text"] ?? xmlURL,
                url: xmlURL,
                siteURL: attributeDict["htmlUrl"],
                collection: stack.last ?? nil))
            stack.append(nil)
        } else {
            stack.append(attributeDict["text"])
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "outline", stack.isEmpty == false else { return }
        stack.removeLast()
    }
}
