import Foundation

/// 工具结果预算（v0.8.51 批 3）。Foundation-only、进 tests/run.sh。
///
/// 单工具结果默认上限 24k 字符；超出**显式截断**并告诉模型"还有内容、怎么取"
/// （不静默丢）。读文件/文档/长日志类工具在表里声明更大预算——readFile 自带
/// 60k 语义，若被统一的 24k 砍半就是能力回归。
nonisolated enum ToolResultBudget {
    static let defaultBudget = 24_000

    static let overrides: [String: Int] = [
        "readFile": 64_000,
        "readURL": 64_000,
        "readPdf": 64_000,
        "readDocument": 32_000,
        "readSpreadsheet": 32_000,
        "readPresentation": 32_000,
        // getPageHTML 维持 48k（2026-11-15 定案）：大结果的正确处理不是收紧
        // 能力，而是"preview → search → slice"三件套——落盘保持完整（句柄/
        // 轨迹/面板读原文），模型侧 >8k 的结果在下一请求自动折叠成 600 字符
        // 预览 + getToolResult 句柄（query 检索 / offset 切片）。
        "getPageHTML": 48_000,
        "runCommand": 48_000,
        "getNetworkLog": 32_000,
    ]

    static func budget(for tool: String) -> Int {
        overrides[tool] ?? defaultBudget
    }

    static func apply(_ result: String, tool: String) -> String {
        // 图片结果（dataURI）不走文本预算：它由 vision 通道按图编码，
        // 截断 base64 会直接毁掉图片（模型解码失败——v0.8.55 批 1 修复，
        // 此前 screenshot 的 base64 一律被 24k 砍断）。
        guard !ToolResultDispatch.isImage(result) else { return result }
        let limit = budget(for: tool)
        guard result.count > limit else { return result }
        let omitted = result.count - limit
        return String(result.prefix(limit))
            + "\n…[truncated \(omitted) chars — narrow the query or use limit/offset; "
            + "for long work prefer a job-based tool]"
    }

    /// **大结果检索**（2026-11-15，"search, don't dump"）：按 query 返回命中
    /// 行 ± 上下文行（带行号）——大 HTML/大文件不用盲目 offset 切片，直接搜
    /// `m3u8|<video|source` 命中处。大小写不敏感子串匹配；命中数与总字符
    /// 双钳制。纯逻辑进 tests/run.sh。nil = 无命中（执行器据此回报）。
    static func search(_ content: String, query: String, maxMatches: Int = 40,
                       contextLines: Int = 1, maxChars: Int = 12_000) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        var chars = 0
        var matches = 0
        var i = 0
        while i < lines.count, matches < maxMatches {
            guard lines[i].lowercased().contains(needle) else { i += 1; continue }
            matches += 1
            let lo = max(0, i - contextLines)
            let hi = min(lines.count - 1, i + contextLines)
            for j in lo...hi {
                let line = "\((j == i ? ">" : " "))\(j + 1): \(lines[j])"
                out.append(line)
                chars += line.count
                if chars > maxChars {
                    out.append("…[search output capped at \(maxChars) chars — narrow the query]")
                    return out.joined(separator: "\n")
                }
            }
            i = hi + 1
        }
        guard matches > 0 else { return nil }
        if i < lines.count {
            out.append("…[\(maxMatches) matches shown — narrow the query for more]")
        }
        return out.joined(separator: "\n")
    }
}
