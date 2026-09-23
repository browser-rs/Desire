import Foundation

enum AgentMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct AgentMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AgentMessageRole
    var content: String?
    var toolCalls: [AgentToolCall]?
    var toolCallId: String?
    var toolName: String?
    /// 推理模型的思考过程（DeepSeek/Qwen 的 `reasoning_content`、部分网关的
    /// `reasoning`/`thinking`）。面板里折叠展示，不进正文，也不回传给模型。
    var reasoning: String?
    /// 回合收尾时模型对自己的**自评**（可选）：只挂在有工具动作的回合上，面板里折叠展示。
    var critique: String?
    /// User-attached images as JPEG data URIs (vision models only; stripped
    /// before persistence so conversation files stay small). Optional, so
    /// conversations saved before this field existed still decode.
    var imageDataURIs: [String]?
    let createdAt: Date

    init(role: AgentMessageRole, content: String? = nil, toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil, images: [String]? = nil, reasoning: String? = nil, critique: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imageDataURIs = images
        self.reasoning = reasoning
        self.critique = critique
        self.createdAt = Date()
    }
}
