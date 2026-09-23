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
    /// 工具执行的墙钟耗时（毫秒）。轨迹里唯一**无法从消息派生**的一项，所以记在工具消息上、
    /// 随会话落盘——这样历史回合导出的轨迹也带耗时。
    var toolDurationMs: Double?
    /// 这次模型调用的 token 用量（服务端在最后一个 chunk 上报；不是所有服务都给）。
    /// 同样记在消息上、随会话落盘——成本要从**历史**会话里算出来，而它派不出来。
    var promptTokens: Int?
    var completionTokens: Int?
    /// 这次回答实际用的模型 id（优先取响应里的 `model`，服务端没给才用请求时所选）。
    /// 成本按它查单价——会话中途换模型、routing 挑模型的场景因此也算得对。
    var model: String?
    /// 用户对该条回答的评价："up" / "down"（可选）。这是**最便宜也最真实的回答质量标签**，
    /// 随会话文件落盘，将来用来攒评估集。
    var feedback: String?
    /// 回合收尾的**机械核验**结论（可选，0 次模型调用）：只讲客观事实，例如"本轮所有工具
    /// 调用都失败却给出了结论"。面板里以橙色折叠块提示用户——不阻塞、不重试。
    var verificationNote: String?
    /// User-attached images as JPEG data URIs (vision models only; stripped
    /// before persistence so conversation files stay small). Optional, so
    /// conversations saved before this field existed still decode.
    var imageDataURIs: [String]?
    let createdAt: Date

    init(role: AgentMessageRole, content: String? = nil, toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil, images: [String]? = nil, reasoning: String? = nil, critique: String? = nil, verificationNote: String? = nil, feedback: String? = nil, toolDurationMs: Double? = nil, promptTokens: Int? = nil, completionTokens: Int? = nil, model: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imageDataURIs = images
        self.reasoning = reasoning
        self.critique = critique
        self.verificationNote = verificationNote
        self.feedback = feedback
        self.toolDurationMs = toolDurationMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.model = model
        self.createdAt = Date()
    }
}
