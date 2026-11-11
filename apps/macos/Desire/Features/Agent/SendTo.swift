import Foundation

/// "发送到…"统一动作（v0.8.53 批 4）：把历史/下载/书签行这类"收藏候选地"
/// 送到白板 / 摘录 / Agent 起草。只复用既有存储路径（白板 note 块、摘录
/// `webSelection`、Agent 草稿收件箱），不新增存储形态。全部 @MainActor。
@MainActor
enum SendTo {
    /// 白板：note 块（标题 + 正文），落到默认板。
    static func whiteboardNote(title: String, content: String) {
        let block = WhiteboardBlock(type: WhiteboardBlock.Kind.note,
                                    title: title.isEmpty ? nil : title,
                                    content: content)
        guard block.isValid else { return }
        WhiteboardStore.shared.append([block], title: nil, conversationID: nil)
    }

    /// 摘录：链接型收集（正文没有页面时，摘录的就是链接本身）。
    @discardableResult
    static func excerptLink(title: String, url: String) -> Bool {
        ExcerptStore.shared.add(kind: .webSelection,
                                title: title.isEmpty ? url : title,
                                source: url,
                                content: url)
    }

    /// Agent 起草：把一段带上下文的请求投进草稿收件箱（面板打开时可见）。
    static func agentDraft(_ text: String) {
        AgentDraftInbox.shared.send(text)
    }
}
