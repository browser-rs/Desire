import Foundation

/// Netscape 书签 HTML（Safari/Chrome/Firefox 导出格式）的**纯解析器**
/// （Foundation-only，进单测 harness；面板与桥都从这里走）。
///
/// 与旧实现的关键差别：`</DL>` 与 `<DT>` 按**出现顺序统一取最近者**处理。
/// 旧实现只在"紧跟 `<DT>` 之后"才检查 `</DL>`，而真实导出里 `</DL>` 出现在
/// 两个 `<DT>` 之间——文件夹永远不回弹，子项被无限嵌套进越来越深的栈里，
/// 最终 `root` 为空：**任何带文件夹的导出文件（也就是全部真实导出）解析
/// 结果都是 0 条**（2026-10-17 导入去重探针暴露；此前导入只有 NSOpenPanel
/// 手工路径，没有自动化覆盖）。
enum BookmarkHTMLParser {

    static func parse(_ html: String) -> [Bookmark] {
        var stack: [Bookmark] = []
        var root: [Bookmark] = []

        func addToCurrent(_ item: Bookmark) {
            if let top = stack.last, top.isFolder {
                stack[stack.count - 1].children.append(item)
            } else {
                root.append(item)
            }
        }

        var searchRange = html.startIndex..<html.endIndex
        scan: while true {
            let dt = html.range(of: "<DT>", options: [.caseInsensitive], range: searchRange)
            let dl = html.range(of: "</DL>", options: [.caseInsensitive], range: searchRange)
            switch (dt, dl) {
            case (nil, nil):
                break scan

            // </DL> 先出现（即位于两个 <DT> 之间）→ 弹一层文件夹。
            case (nil, .some(let close)):
                searchRange = close.upperBound..<html.endIndex
                if let folder = stack.popLast() { addToCurrent(folder) }

            case (.some(let dtRange), .some(let close)) where close.lowerBound < dtRange.lowerBound:
                searchRange = close.upperBound..<html.endIndex
                if let folder = stack.popLast() { addToCurrent(folder) }

            case (.some(let dtRange), _):
                searchRange = dtRange.upperBound..<html.endIndex
                let rest = html[searchRange]

                if rest.hasPrefix("<A ") || rest.hasPrefix("<A\t") || rest.hasPrefix("<A\n") {
                    guard let hrefStart = rest.range(of: "HREF=\"", options: [.caseInsensitive]) else { continue }
                    let urlStart = hrefStart.upperBound
                    guard let urlEnd = rest[urlStart...].firstIndex(of: "\"") else { continue }
                    let url = String(rest[urlStart..<urlEnd])

                    let afterURL = rest[urlEnd...]
                    guard let closeTag = afterURL.range(of: "</A>", options: [.caseInsensitive]) else { continue }
                    let tagStart = afterURL.firstIndex(of: ">") ?? urlEnd
                    let titleEnd = closeTag.lowerBound
                    let title = (tagStart < titleEnd)
                        ? String(afterURL[afterURL.index(after: tagStart)..<titleEnd])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\t", with: " ")
                            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                        : ""
                    searchRange = closeTag.upperBound..<html.endIndex
                    // 属性区 = 整个 <A …> 开标签（TAGS 可能在 HREF 前）；
                    // rest/tagStart 同源于 html，索引可跨切片比较。
                    addToCurrent(Bookmark.leaf(title: title.isEmpty ? url : title, url: url,
                                               tags: Self.parseTAGS(in: rest, before: tagStart)))

                } else if rest.hasPrefix("<H3") || rest.hasPrefix("<H3\t") || rest.hasPrefix("<H3\n") {
                    guard let closeTag = rest.range(of: "</H3>", options: [.caseInsensitive]) else { continue }
                    let titleStart = rest.firstIndex(of: ">") ?? rest.startIndex
                    let titleEnd = closeTag.lowerBound
                    let title = (titleStart < titleEnd)
                        ? String(rest[rest.index(after: titleStart)..<titleEnd])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        : ""
                    searchRange = closeTag.upperBound..<html.endIndex
                    stack.append(Bookmark.folder(title: title.isEmpty ? String(localized: "Folder") : title))

                } else if rest.hasPrefix("<HR") || rest.hasPrefix("<META") || rest.hasPrefix("<!") {
                    guard let end = rest.range(of: ">") else { continue }
                    searchRange = end.upperBound..<html.endIndex

                } else if rest.hasPrefix("<p>") || rest.hasPrefix("<P>") {
                    searchRange = html.index(searchRange.lowerBound, offsetBy: 3)..<html.endIndex

                } else {
                    searchRange = html.index(after: searchRange.lowerBound)..<html.endIndex
                }
            }
        }
        // 未闭合的文件夹（文件被截断）也收进结果，不丢数据。**必须先 pop
        // 再挂**：addToCurrent 看到栈顶仍是自己时会把文件夹挂进它自己。
        while let folder = stack.popLast() { addToCurrent(folder) }
        return root
    }
    /// TAGS="a,b" 属性解析（v0.8.6）：看整个开标签属性段（TAGS 与 HREF
    /// 顺序不定）；逗号切分、去空白、空项丢弃，无属性返回 nil。
    private static func parseTAGS(in slice: Substring, before close: String.Index) -> [String]? {
        guard close > slice.startIndex else { return nil }
        let attrs = slice[..<close]
        guard let start = attrs.range(of: "TAGS=\"", options: [.caseInsensitive]) else { return nil }
        let valueStart = start.upperBound
        guard let valueEnd = attrs[valueStart...].firstIndex(of: "\"") else { return nil }
        let tags = attrs[valueStart..<valueEnd]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return tags.isEmpty ? nil : tags
    }

}
