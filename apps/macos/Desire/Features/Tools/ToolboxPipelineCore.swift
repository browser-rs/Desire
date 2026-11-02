import Foundation

/// 流水线执行核心（v0.8.38 A5，纯逻辑进 tests/run.sh）。
///
/// 语义：
/// - 每步 `arguments` 先按工具 spec 原样传入；`inputKey` 非 nil 时把上一步
///   输出写进该键（覆盖同名固定参数）。
/// - 工具返回 `ok=false` 立即停止，`failedIndex` 指向该步；已完成步骤的
///   输出保留（UI 可定位中间产物）。
/// - 未知工具名视为该步失败，不执行后续步骤。
nonisolated enum ToolboxPipelineCore {
    struct StepResult: Equatable {
        var index: Int
        var tool: String
        var ok: Bool
        var text: String
    }

    struct RunResult: Equatable {
        var ok: Bool
        var steps: [StepResult]
        var finalText: String
        var failedIndex: Int?
    }

    /// 保存前校验：返回 nil = 可保存；否则是给用户看的错误。
    static func validationError(for pipeline: ToolboxPipeline) -> String? {
        if pipeline.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Give the pipeline a name.")
        }
        if pipeline.steps.isEmpty {
            return String(localized: "Add at least one step.")
        }
        for step in pipeline.steps where !ToolboxRuntimeCore.toolNames.contains(step.tool) {
            return String(localized: "Unknown tool: \(step.tool)")
        }
        return nil
    }

    static func run(_ pipeline: ToolboxPipeline, initialText: String) -> RunResult {
        var current = initialText
        var results: [StepResult] = []
        for (index, step) in pipeline.steps.enumerated() {
            guard ToolboxRuntimeCore.toolNames.contains(step.tool) else {
                results.append(StepResult(index: index, tool: step.tool, ok: false,
                                          text: String(localized: "Unknown tool: \(step.tool)")))
                return RunResult(ok: false, steps: results, finalText: current,
                                 failedIndex: index)
            }
            var arguments = step.arguments
            if let key = step.inputKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                arguments[key] = current
            }
            let output = ToolboxRuntimeCore.run(tool: step.tool, args: arguments)
            results.append(StepResult(index: index, tool: step.tool,
                                      ok: output.ok, text: output.text))
            if !output.ok {
                return RunResult(ok: false, steps: results, finalText: current,
                                 failedIndex: index)
            }
            current = output.text
        }
        return RunResult(ok: true, steps: results, finalText: current, failedIndex: nil)
    }

    /// 编辑器里的紧凑参数串：`key=value; key2=value2`（用分号，值里可含逗号）。
    static func encodeArguments(_ arguments: [String: String]) -> String {
        arguments.keys.sorted()
            .map { "\($0)=\(arguments[$0] ?? "")" }
            .joined(separator: "; ")
    }

    static func decodeArguments(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first?.trimmingCharacters(in: .whitespaces),
                  !key.isEmpty else { continue }
            let value = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : ""
            result[key] = value
        }
        return result
    }
}
