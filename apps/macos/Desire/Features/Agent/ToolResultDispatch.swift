import Foundation

/// 工具结果分发载荷（v0.8.51 批 4）：白板 / 摘录 / Markdown 三种出口的
/// **纯构造**——Foundation-only、进 tests/run.sh。
///
/// 口径：
/// - 图片结果（`data:image/…`）不进文本出口（白板图片走截图入口）；
/// - 存储类出口有长度上限，超出显式标记（与工具结果预算同一原则）；
/// - Markdown 围栏按内容里最长的反引号串加一，避免结果自带 ``` 把围栏提前关掉。
nonisolated enum ToolResultDispatch {
    /// 白板块 / 摘录正文的上限（摘录库与 DiskStore 都要落盘，别存整页 HTML）。
    static let contentLimit = 20_000

    static func isImage(_ result: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("data:image/")
    }

    /// 可用于文本出口的内容（去首尾空白；空与图片返回 nil）。
    static func text(_ result: String) -> String? {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:image/") else { return nil }
        return trimmed
    }

    static func clipped(_ text: String) -> String {
        guard text.count > contentLimit else { return text }
        return String(text.prefix(contentLimit))
            + "\n…[truncated \(text.count - contentLimit) chars]"
    }

    /// 内容像 JSON（对象/数组）就用 json 围栏，语法高亮更好读。
    static func fenceLanguage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return ""
        }
        return "json"
    }

    static func markdown(tool: String, result: String) -> String {
        guard let body = text(result) else { return "" }
        let clippedBody = clipped(body)
        let fence = fenceFor(clippedBody)
        let language = fenceLanguage(clippedBody)
        return "### \(tool)\n\n\(fence)\(language)\n\(clippedBody)\n\(fence)"
    }

    /// 比内容里最长的反引号串多一个（最少三个）。
    static func fenceFor(_ text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// 发到白板的载荷（标题 + 笔记正文）。**不在这里构造 WhiteboardBlock**：
    /// 白板模型在 app target 里是 MainActor 隔离的，而本文件要能在
    /// Foundation-only harness 里同步调用；块由 `ToolResultDispatcher` 组装。
    struct WhiteboardPayload: Equatable {
        let title: String
        let content: String
    }

    static func whiteboardPayload(tool: String, result: String) -> WhiteboardPayload? {
        guard text(result) != nil else { return nil }
        return WhiteboardPayload(title: tool, content: markdown(tool: tool, result: result))
    }

    /// 存为摘录：正文 = 结果原文（不带 Markdown 包装），超限截断标记。
    static func excerptContent(tool: String, result: String) -> String? {
        guard let body = text(result) else { return nil }
        _ = tool
        return clipped(body)
    }
}
