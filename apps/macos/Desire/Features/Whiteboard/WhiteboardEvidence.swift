import Foundation

/// image 块的证据引用解析：模型用 `{"type":"image","evidence":"last"}` 引用
/// **最近一张截图工具的结果**（screenshot / screenshotElement 的返回就是
/// data URI），而不必把几 MB 的 base64 原样回传进 whiteboard 参数——
/// 那是纯粹的钱包灾难。也接受显式 toolCallId。解析由宿主侧完成
/// （白板工具与桥共用），解析失败时模型收到明确的 Error。
@MainActor
enum WhiteboardEvidence {
    /// 就地解析 rawBlocks 里带 evidence 键的 image 块：成功 → content 被
    /// 填上 data URI、evidence 键移除；失败 → 返回未解析的引用描述。
    /// 返回 nil 表示全部解析成功（或不涉及 evidence）。
    static func resolve(_ rawBlocks: inout [[String: Any]], messages: [AgentMessage]) -> String? {
        for i in rawBlocks.indices {
            guard let ref = rawBlocks[i]["evidence"] as? String else { continue }
            guard rawBlocks[i]["type"] as? String == WhiteboardBlock.Kind.image else {
                return "block \(i + 1): evidence only applies to type=image"
            }
            if let uri = Self.dataURI(for: ref, messages: messages) {
                rawBlocks[i]["content"] = uri
                rawBlocks[i].removeValue(forKey: "evidence")
            } else {
                return ref == "last"
                    ? "evidence=last: no screenshot found in this conversation — call screenshot (or screenshotElement) first"
                    : "evidence=\(ref): no image result for that toolCallId"
            }
        }
        return nil
    }

    /// ref = "last"（最近一条 data:image 工具结果）或显式 toolCallId。
    static func dataURI(for ref: String, messages: [AgentMessage]) -> String? {
        switch ref {
        case "last":
            return messages.last { $0.role == .tool && ($0.content ?? "").hasPrefix("data:image/") }?.content
        default:
            return messages.last { $0.role == .tool && $0.toolCallId == ref && ($0.content ?? "").hasPrefix("data:image/") }?.content
        }
    }
}
