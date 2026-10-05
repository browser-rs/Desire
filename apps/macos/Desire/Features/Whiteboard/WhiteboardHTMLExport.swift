import Foundation

/// 白板 → 单文件 HTML 导出（0.6.7）：零外部依赖的静态 viewer——
/// mermaid/chart 以代码块呈现源码，note/table 渲染排版，image 内联
/// data URI 直接显示。产物双击即可在任意浏览器打开（无 Desire 机器可读）。
enum WhiteboardHTMLExport {
    /// 块文本 HTML 转义。
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// markdown 表格 → HTML 表格（与白板渲染器的轻量解析同口径：
    /// `|` 分割、第二行分隔线跳过）。
    static func markdownTableHTML(_ content: String) -> String {
        let rows = content.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !rows.isEmpty else { return "" }
        var out = "<table>"
        for (i, row) in rows.enumerated() {
            let cells = row.split(separator: "|", omittingEmptySubsequences: true)
                .map { "<td>\(esc($0.trimmingCharacters(in: .whitespaces)))</td>" }
                .joined()
            let tag = i == 0 ? "th" : "td"
            let wrapped = cells.replacingOccurrences(of: "<td>", with: "<\(tag)>")
                .replacingOccurrences(of: "</td>", with: "</\(tag)>")
            out += "<tr>\(wrapped)</tr>"
        }
        out += "</table>"
        return out
    }

    /// 单块 → HTML 片段。
    static func blockHTML(_ block: WhiteboardBlock) -> String {
        var out = "<section class='block'>"
        if let title = block.title, !title.isEmpty {
            out += "<h3>\(esc(title))</h3>"
        }
        switch block.type {
        case WhiteboardBlock.Kind.mermaid:
            out += "<pre class='src mermaid-src'>\(esc(block.content))</pre>"
        case WhiteboardBlock.Kind.chart:
            out += "<pre class='src'>\(esc(block.content))</pre>"
        case WhiteboardBlock.Kind.table:
            out += markdownTableHTML(block.content)
        case WhiteboardBlock.Kind.image:
            out += "<img src='\(block.content)' alt='board image'>"
        default: // note
            out += "<p class='note'>\(esc(block.content))</p>"
        }
        out += "</section>"
        return out
    }

    /// 整板 HTML 文档。
    static func document(for spec: WhiteboardSpec) -> String {
        let body: String
        if spec.blocks.isEmpty {
            body = "<p class='empty'>（白板为空）</p>"
        } else {
            body = spec.blocks.map { blockHTML($0) }.joined(separator: "\n")
        }
        let title = esc(spec.title)
        return """
        <!DOCTYPE html>
        <html lang="zh-Hans">
        <head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          body { font-family: -apple-system, "PingFang SC", sans-serif; max-width: 760px;
                 margin: 0 auto; padding: 24px 16px; color: #211b13;
                 background: #f6f1e7; line-height: 1.6; }
          h1 { font-size: 22px; }
          h3 { font-size: 14px; margin: 0 0 6px; }
          section.block { background: #fffdf7; border: 1px solid #d8cfba;
                          border-radius: 8px; padding: 12px 16px; margin: 14px 0; }
          pre.src { background: #2d2a24; color: #f5efe0; padding: 10px 12px;
                    border-radius: 6px; overflow-x: auto; font-size: 12px; }
          pre.src code { all: unset; }
          img { max-width: 100%; border-radius: 6px; }
          table { border-collapse: collapse; width: 100%; font-size: 13px; }
          th, td { border: 1px solid #d8cfba; padding: 4px 8px; text-align: left; }
          th { background: #eee7d7; }
          .empty { color: #8a7f6f; }
        </style>
        </head><body>
        \(body)
        </body></html>
        """
    }
}
