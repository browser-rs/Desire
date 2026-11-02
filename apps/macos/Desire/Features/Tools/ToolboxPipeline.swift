import Foundation

/// 工具箱流水线（v0.8.38 A5）：把纯文本工具串成可复用的多步流程。
/// 每一步可把上一步的输出注入指定参数（默认 `text`），失败即停、保留中间结果。
nonisolated struct ToolboxPipeline: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var steps: [ToolboxPipelineStep]
    var updatedAt: Date

    init(id: UUID = UUID(), name: String,
         steps: [ToolboxPipelineStep] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

nonisolated struct ToolboxPipelineStep: Codable, Identifiable, Equatable {
    var id: UUID
    /// 工具名（必须存在于 ToolboxRuntimeCore.toolNames）
    var tool: String
    /// 固定参数（键名与工具 spec 一致）
    var arguments: [String: String]
    /// 非 nil = 把上一步输出写进这个参数（通常是 `text`）。
    var inputKey: String?

    init(id: UUID = UUID(), tool: String,
         arguments: [String: String] = [:], inputKey: String? = "text") {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.inputKey = inputKey
    }
}
