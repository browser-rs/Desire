import Foundation

/// **大结果转存**（2026-11-15，用户定案"转存为文件、上下文保存文件地址、
/// 需要时检索文件"）：工具结果超过该工具的预算时，**全文写工作区
/// `tool-results/`**，上下文里只留"头 4000 + 尾 1000 + 绝对路径标记"。
///
/// 此前的做法是硬截断（24k/48k 一刀切丢尾巴）——小说级长文本直接被砍，
/// 且 48k 一条就把落盘历史顶过预算线。转存后：
/// · 上下文占用与结果大小解耦（预览固定 ~5k，且低于请求侧 8k 折叠阈值，
///   后续请求不会被二次折叠）；
/// · 全文仍可达：getToolResult(callId) 对转存结果自动回退读文件
///   （query= grep 式命中 / offset+length= 切片），readFile 也能直接读路径；
/// · 面板/轨迹读消息内容 = 预览 + 路径（全文在文件里）。
/// 文件按 `<工具名>-<callId 前 8 位>.txt` 命名、不平铺清理（用户可能事后
/// 翻阅；目录在 agent 工作区内，用户自己可见可删）。
nonisolated enum ToolResultSpill {

    /// 预览形状：头 4000 + 尾 1000。
    static let headChars = 4_000
    static let tailChars = 1_000
    /// 解析标记（独立一行，路径任意字符都稳）。
    static let markerPrefix = "[desire-spill: "

    /// 全文转存并返回"头尾预览 + 路径标记"。调用方保证 result 确实超预算
    /// 且不是图片结果。
    static func spill(_ result: String, tool: String, callID: String,
                      directory: URL) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTool = String(tool.filter { $0.isLetter || $0.isNumber }.prefix(32))
        let file = directory.appendingPathComponent("\(safeTool)-\(callID.prefix(8)).txt")
        try? result.write(to: file, atomically: true, encoding: .utf8)
        let head = String(result.prefix(headChars))
        let tail = result.count > headChars + tailChars ? String(result.suffix(tailChars)) : ""
        let omitted = result.count - head.count - tail.count
        return head
            + "\n…[result truncated for context: \(result.count) chars total, middle \(omitted) omitted — "
            + "full text saved to file (retrieve via getToolResult(callId: \"\(callID)\") with "
            + "query= grep-style hits / offset+length= slices, or readFile)]"
            + (tail.isEmpty ? "" : "\n" + tail)
            + "\n\(markerPrefix)\(file.path)]"
    }

    /// 从工具消息内容解析转存路径；nil = 非转存结果。
    static func parsePath(from content: String) -> String? {
        guard let start = content.range(of: markerPrefix) else { return nil }
        let rest = String(content[start.upperBound...])
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let path = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? path : nil
    }

    /// 转存全文（供 getToolResult 回退读文件）。nil = 文件丢失。
    static func readFile(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
