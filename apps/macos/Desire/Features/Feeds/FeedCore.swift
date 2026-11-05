import Foundation

/// RSS 2.0 / Atom 1.0 解析与文章台账合并（v0.8.45 批 1）。
/// Foundation-only，进 tests/run.sh。容错口径：缺 guid 用 link、再缺用 title
/// 派生；缺日期用抓取时间；摘要剥标签截断 500 字。XMLParser 委托类 nonisolated
/// （回调在 parser.parse 的调用线程上同步触发）。
nonisolated enum FeedCore {

    static let maxItemsPerFeed = 500
    static let maxSummaryLength = 500

    struct FeedMeta: Equatable, Sendable {
        var title: String
        var siteURL: String?
        var feedDescription: String?
    }

    struct ItemDraft: Equatable, Sendable {
        var guid: String
        var title: String
        var link: String?
        var publishedAt: Date?
        var summary: String?
        var author: String?
    }

    struct ParseResult: Equatable, Sendable {
        var meta: FeedMeta
        var items: [ItemDraft]
    }

    // MARK: - 解析

    /// 解析 feed 文档；失败（非法 XML / 无条目）返回 nil。编码按 XML 声明走
    /// （XMLParser 自认）；声明缺失或解码失败再试一次 UTF-8 lossy。
    static func parse(data: Data, fetchedAt: Date) -> ParseResult? {
        if let result = parseRaw(data: data, fetchedAt: fetchedAt) {
            return result
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\u{FFFD}") == false || data.count > 0 else {
            return nil
        }
        return parseRaw(data: Data(text.utf8), fetchedAt: fetchedAt)
    }

    private static func parseRaw(data: Data, fetchedAt: Date) -> ParseResult? {
        let delegate = FeedParserDelegate(fetchedAt: fetchedAt)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.items.isEmpty == false || delegate.meta.title.isEmpty == false else {
            return nil
        }
        return ParseResult(meta: delegate.meta, items: delegate.items)
    }

    // MARK: - 台账合并

    /// 抓取结果合入既有台账：guid 去重（已存在的只补摘要缺失）、新文章排在
    /// 后面返回 newCount、超上限先淘汰最旧的未星标（星标最后才动）。
    static func merge(existing: [FeedItem], drafts: [ItemDraft], feedURL: String,
                      fetchedAt: Date, cap: Int = maxItemsPerFeed)
        -> (items: [FeedItem], newCount: Int) {
        var byID = Dictionary(existing.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var newCount = 0
        for draft in drafts {
            let id = itemID(guid: draft.guid, link: draft.link, title: draft.title)
            if byID[id] != nil {
                // 已知文章：只在原摘要缺失时补
                if let index = existing.firstIndex(where: { $0.id == id }),
                   existing[index].summary == nil, let summary = draft.summary {
                    byID[id]?.summary = summary
                }
                continue
            }
            newCount += 1
            byID[id] = FeedItem(
                id: id, feedURL: feedURL,
                title: draft.title.isEmpty ? "(untitled)" : draft.title,
                link: draft.link,
                publishedAt: draft.publishedAt ?? fetchedAt,
                summary: draft.summary, author: draft.author,
                isRead: false, isStarred: false, firstSeenAt: fetchedAt)
        }
        var items = Array(byID.values)
        if items.count > cap {
            // 淘汰顺序：已读优先于未读、旧优先于新、星标绝对不动
            items.sort { left, right in
                if left.isStarred != right.isStarred { return left.isStarred }
                if left.isRead != right.isRead { return right.isRead }
                return left.publishedAt > right.publishedAt
            }
            items = Array(items.prefix(cap))
        }
        return (items, newCount)
    }

    /// 稳定条目 id：guid → link → title 派生（同 feed 内唯一即可）。
    static func itemID(guid: String, link: String?, title: String) -> String {
        let trimmedGUID = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGUID.isEmpty { return trimmedGUID }
        if let link = link?.trimmingCharacters(in: .whitespacesAndNewlines),
           !link.isEmpty { return link }
        return "title:" + title
    }

    /// 摘要清洗：剥标签 + 实体解码 + 空白折叠 + 截断。复用书搜的 plainText。
    static func summary(fromRaw raw: String?) -> String? {
        guard let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        var text = EbookSearchCore.plainText(fromHTML: raw)
        if text.count > maxSummaryLength {
            text = String(text.prefix(maxSummaryLength)) + "…"
        }
        return text.isEmpty ? nil : text
    }
}

/// XMLParser 委托：RSS 2.0（channel/item）与 Atom 1.0（feed/entry）双格式。
/// 状态机按元素名入栈；未知元素忽略。nonisolated —— 回调同步于调用线程。
private nonisolated final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private let fetchedAt: Date
    private var stack: [String] = []
    private var buffer = ""
    private(set) var meta = FeedCore.FeedMeta(title: "", siteURL: nil, feedDescription: nil)
    private(set) var items: [FeedCore.ItemDraft] = []

    // 当前条目累积
    private var currentGUID = ""
    private var currentTitle = ""
    private var currentLink: String?
    private var currentPublished: Date?
    private var currentSummary: String?
    private var currentAuthor: String?
    /// Atom link 的 rel 判别（alternate → 站点/文章链接）
    private var linkRel = ""
    private var linkHref = ""
    /// RSS <enclosure> 等忽略名单外的容器（item/entry）判定
    private var inChannel = false

    init(fetchedAt: Date) {
        self.fetchedAt = fetchedAt
    }

    private var isInItem: Bool { stack.contains("item") || stack.contains("entry") }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        stack.append(elementName)
        buffer = ""
        switch elementName {
        case "channel", "feed":
            inChannel = true
        case "item", "entry":
            currentGUID = ""
            currentTitle = ""
            currentLink = nil
            currentPublished = nil
            currentSummary = nil
            currentAuthor = nil
        case "link":
            linkRel = attributeDict["rel"] ?? ""
            linkHref = attributeDict["href"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            buffer += text
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            stack.removeLast()
            buffer = ""
        }
        // (元素名, 是否条目内) 元组匹配——`where` 只约束最后一个 pattern 的
        // 写法在多 pattern case 里会静默漏判（Swift 6.4 警告）。
        switch (elementName, isInItem) {
        // feed 级
        case ("title", false):
            meta.title = text
        case ("subtitle", false), ("description", false):
            if meta.feedDescription == nil, !text.isEmpty {
                meta.feedDescription = FeedCore.summary(fromRaw: text)
            }
        case ("link", false):
            // Atom：<link rel="alternate" href="…"/>；RSS：<link>text</link>
            if !text.isEmpty, meta.siteURL == nil {
                meta.siteURL = text
            } else if linkRel == "alternate" || (linkRel.isEmpty && !linkHref.isEmpty) {
                if meta.siteURL == nil, !linkHref.isEmpty { meta.siteURL = linkHref }
            }
        // 条目边界
        case ("item", _), ("entry", _):
            finishItem()
        case ("title", true):
            currentTitle = text
        case ("guid", true), ("id", true):
            if currentGUID.isEmpty, !text.isEmpty { currentGUID = text }
        case ("link", true):
            if !text.isEmpty {
                if currentLink == nil { currentLink = text }
            } else if linkRel == "alternate" || (linkRel.isEmpty && !linkHref.isEmpty) {
                if currentLink == nil, !linkHref.isEmpty { currentLink = linkHref }
            }
        case ("pubDate", true), ("published", true), ("updated", true):
            if currentPublished == nil, !text.isEmpty {
                currentPublished = FeedDate.parse(text)
            }
        case ("description", true), ("summary", true), ("content", true):
            if currentSummary == nil, !text.isEmpty {
                currentSummary = FeedCore.summary(fromRaw: text)
            }
        case ("author", true), ("name", true):
            if currentAuthor == nil, !text.isEmpty { currentAuthor = text }
        default:
            break
        }
    }

    private func finishItem() {
        let id = FeedCore.itemID(guid: currentGUID, link: currentLink, title: currentTitle)
        guard !id.isEmpty else { return }
        items.append(FeedCore.ItemDraft(
            guid: id,
            title: currentTitle,
            link: currentLink,
            publishedAt: currentPublished,
            summary: currentSummary,
            author: currentAuthor))
    }
}

/// feed 日期解析（RFC 822 与 ISO 8601 双格式；解析失败返回 nil → 上层用抓取时间）。
nonisolated enum FeedDate {
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let rfc822Short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFraction = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rfc822.date(from: trimmed)
            ?? rfc822Short.date(from: trimmed)
            ?? iso.date(from: trimmed)
            ?? isoNoFraction.date(from: trimmed)
    }
}
