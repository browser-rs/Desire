import Foundation

/// 后台命令模板（v0.8.40）：把常用的构建/测试/CI/转码命令保存下来，
/// Jobs 中心与 Agent 都能一键运行。只存 argv，不含 shell。
nonisolated struct JobTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var tool: String
    var args: [String]
    var cwd: String?
    var timeoutMinutes: Double
    var maxAttempts: Int
    var retryOn: String
    var priority: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, tool: String, args: [String] = [],
         cwd: String? = nil, timeoutMinutes: Double = 60,
         maxAttempts: Int = 1, retryOn: String = "nonZero",
         priority: String = "normal", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tool = tool
        self.args = args
        self.cwd = cwd
        self.timeoutMinutes = timeoutMinutes
        self.maxAttempts = maxAttempts
        self.retryOn = retryOn
        self.priority = priority
        self.createdAt = createdAt
    }
}

nonisolated enum JobTemplateValidation {
    static func error(name: String, tool: String, args: [String]) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Give the template a name.")
        }
        if tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Missing tool.")
        }
        if args.count > 64 {
            return String(localized: "Too many arguments (max 64).")
        }
        return nil
    }
}
