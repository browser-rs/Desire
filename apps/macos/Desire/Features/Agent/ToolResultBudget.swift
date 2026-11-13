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
}
