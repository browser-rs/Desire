import Foundation

/// DPP 一键上板（0.6.9）：`pageExtract` 工具结果 → 白板块的纯转换。
/// 结果文本形态 = `"Extracted <view> (N page(s), <scope>):\n<JSON 数组>"`；
/// 转成 说明 note（视图名 + 条数）+ Markdown 表格（列 = 各条目的键并集，
/// 排序稳定；单元格截短防炸帧）。Foundation-only，进 tests/run.sh。
enum WhiteboardExtract {
    /// 解析并转换。nil = 没有 pageExtract 形态的文本（调用方报 Error: 让模型先抽取）；
    /// 空列表返回空块数组（合法空抽取，调用方自行措辞）。
    static func blocks(
        fromToolResult text: String, viewNameOut: inout String?,
        maxRows: Int = 40, maxCellChars: Int = 80
    ) -> [WhiteboardBlock]? {
        // 结果头："Extracted <view> (…):" —— 视图名取首行括号前的部分。
        guard let lineEnd = text.firstIndex(of: "\n") else { return nil }
        let head = String(text[..<lineEnd])
        guard head.hasPrefix("Extracted ") else { return nil }
        let view = head.dropFirst("Extracted ".count)
            .prefix(while: { $0 != "(" })
            .trimmingCharacters(in: .whitespaces)
        viewNameOut = view.isEmpty ? nil : String(view)

        // JSON 数组体：头行之后的第一个 "[" 起到最后。
        let rest = String(text[text.index(after: lineEnd)...])
        guard let jsonStart = rest.firstIndex(of: "["),
              let data = rest[jsonStart...].data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        if items.isEmpty { return [] }   // 合法空抽取：空块数组，调用方自行措辞

        var keys: [String] = []
        for item in items.prefix(10) {
            for key in item.keys where !keys.contains(key) {
                keys.append(key)
            }
        }
        keys.sort()
        let cappedItems = items.prefix(maxRows)

        var table = "| " + keys.joined(separator: " | ") + " |\n"
        table += "| " + keys.map { _ in "---" }.joined(separator: " | ") + " |\n"
        for item in cappedItems {
            let cells = keys.map { key -> String in
                let raw = item[key]
                let rendered: String
                switch raw {
                case nil: rendered = ""
                case is NSNull: rendered = ""
                case let value as String: rendered = value
                case let value as [String: Any]:
                    rendered = (try? JSONSerialization.data(withJSONObject: value))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
                case let value as [Any]:
                    rendered = (try? JSONSerialization.data(withJSONObject: value))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
                default: rendered = "\(raw!)"
                }
                let oneLine = rendered.replacingOccurrences(of: "\n", with: " ")
                return oneLine.count > maxCellChars
                    ? String(oneLine.prefix(maxCellChars)) + "…"
                    : oneLine
            }
            table += "| " + cells.joined(separator: " | ") + " |\n"
        }

        var note = "## \(view.isEmpty ? "Extract" : view)\n\(items.count) item(s)"
        if items.count > maxRows { note += "（表格只展示前 \(maxRows) 行）" }
        let noteBlock = WhiteboardBlock(type: WhiteboardBlock.Kind.note, title: nil, content: note)
        let tableBlock = WhiteboardBlock(type: WhiteboardBlock.Kind.table, title: nil, content: table)
        return [noteBlock, tableBlock]
    }
}
