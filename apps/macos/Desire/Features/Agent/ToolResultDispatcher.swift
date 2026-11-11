import Foundation

/// 工具结果一键分发（v0.8.51 批 4）：把纯构造的载荷落进既有存储。
/// 白板跟会话走（`conversationID` 由调用方给，缺省 = 默认板）；
/// 摘录复用 `.webSelection` 类型，来源由调用方给（页面标题/URL 或工具箱）。
@MainActor
enum ToolResultDispatcher {
    @discardableResult
    static func sendToWhiteboard(tool: String, result: String,
                                 conversationID: String?) -> Bool {
        guard let payload = ToolResultDispatch.whiteboardPayload(tool: tool, result: result) else {
            return false
        }
        let block = WhiteboardBlock(type: WhiteboardBlock.Kind.note,
                                    title: payload.title,
                                    content: payload.content)
        guard block.isValid else { return false }
        WhiteboardStore.shared.append([block], title: nil, conversationID: conversationID)
        return true
    }

    @discardableResult
    static func saveExcerpt(tool: String, result: String,
                            sourceTitle: String, sourceURL: String) -> Bool {
        guard let content = ToolResultDispatch.excerptContent(tool: tool, result: result) else {
            return false
        }
        return ExcerptStore.shared.add(kind: .webSelection,
                                       title: sourceTitle.isEmpty ? tool : sourceTitle,
                                       source: sourceURL.isEmpty ? "desire://agent" : sourceURL,
                                       content: content)
    }
}
