import Foundation

/// 后台命令模板（v0.8.40）：把常用的构建/测试/CI/转码命令保存下来，
/// Jobs 中心与 Agent 都能一键运行。只存 argv，不含 shell。
/// 作业链（v0.8.57 批 2）：`steps` 非空时按链推进（command/officeBatch/
/// imageBatch，`{prev.artifact}`/`{prev.artifactDir}` 占位符串起产物）；
/// nil/空 = 旧单命令模板（单步链，语义不变——向后兼容旧存储）。
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
    var steps: [JobChainCore.Step]?

    init(id: UUID = UUID(), name: String, tool: String, args: [String] = [],
         cwd: String? = nil, timeoutMinutes: Double = 60,
         maxAttempts: Int = 1, retryOn: String = "nonZero",
         priority: String = "normal", createdAt: Date = Date(),
         steps: [JobChainCore.Step]? = nil) {
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
        self.steps = steps
    }

    /// 链视图：steps 非空用链；否则由单命令字段合成单步链。
    var chainSteps: [JobChainCore.Step] {
        if let steps, !steps.isEmpty { return steps }
        return [JobChainCore.Step(kind: .command, params: [
            "tool": tool, "args": JobChainEncoding.jsonArray(args),
            "cwd": cwd ?? "", "timeoutMinutes": String(timeoutMinutes),
        ])]
    }
}

/// 链 params 的编解码辅助（params 值是字符串——数组走 JSON 字符串）。
nonisolated enum JobChainEncoding {
    static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeArray(_ text: String) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? []
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
