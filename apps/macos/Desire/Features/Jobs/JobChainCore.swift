import Foundation

/// 作业链（v0.8.57 批 2）：steps 数组按序推进——上一步终态 `done` 后替换
/// 占位符启动下一步；`failed/cancelled` 停链（已成功步不回滚）。
/// 占位符：`{prev.artifact}` = 上一步产物路径；`{prev.artifactDir}` =
/// 产物所在目录（目录产物即其自身）。推进状态机与替换是**纯逻辑**，
/// 进 tests/run.sh；启动器（command/officeBatch/imageBatch）在 Runner。
nonisolated enum JobChainCore {

    nonisolated enum StepKind: String, Codable, Sendable, CaseIterable {
        case command, officeBatch, imageBatch

        /// 大小写不敏感解析（桥/模型常给 officebatch）。
        static func parse(_ raw: String) -> StepKind? {
            if let exact = StepKind(rawValue: raw) { return exact }
            return allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        }
    }

    nonisolated struct Step: Codable, Equatable, Sendable {
        var kind: StepKind
        /// JSON 对象模板（值里可含占位符；command 的键为 tool/args/cwd）。
        var params: [String: String]

        enum CodingKeys: String, CodingKey { case kind, params }
    }

    /// 占位符标记。
    static let artifactToken = "{prev.artifact}"
    static let artifactDirToken = "{prev.artifactDir}"

    /// 上一步的产物视角：目录产物（路径以 / 结尾或无扩展名）= 自身
    /// （**规范去尾斜杠**——模板自己拼 `/`）；文件产物 = 所在目录。
    static func artifactDir(of path: String) -> String {
        let kind = ArtifactIndex.classify(path: path)
        if kind == .folder {
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// 对一个字符串值做占位符替换（未知占位符原样保留——校验层报错）。
    static func substituteValue(_ value: String, artifactPath: String) -> String {
        value
            .replacingOccurrences(of: artifactToken, with: artifactPath)
            .replacingOccurrences(of: artifactDirToken, with: artifactDir(of: artifactPath))
    }

    /// 对步骤 params 全量替换。返回还残留占位符的键（校验用）。
    static func substitute(_ params: [String: String],
                           artifactPath: String) -> (resolved: [String: String], unresolved: [String]) {
        var out: [String: String] = [:]
        var unresolved: [String] = []
        for (key, value) in params {
            let replaced = substituteValue(value, artifactPath: artifactPath)
            out[key] = replaced
            if replaced.contains(artifactToken) || replaced.contains(artifactDirToken) {
                unresolved.append(key)
            }
        }
        return (out, unresolved)
    }

    /// 校验：第一步不得含占位符（没有"上一步"可解析）；后续步骤允许但
    /// 必须至少引用一个已知占位符的步骤在前。返回错误描述（nil = 合法）。
    static func validationError(steps: [Step]) -> String? {
        guard !steps.isEmpty else { return String(localized: "A chain needs at least one step.") }
        for (index, step) in steps.enumerated() {
            if index == 0 {
                let raw = (step.params.values.joined(separator: " "))
                if raw.contains(artifactToken) || raw.contains(artifactDirToken) {
                    return String(localized: "Step 1 cannot reference a previous artifact — there is none yet.")
                }
            }
        }
        return nil
    }

    /// 推进决策（纯函数）：给定刚结束的步骤与终态，返回链的下一动作。
    /// 参数替换由 Runner 用 `substitute` 在启动前完成（这里只定下标）。
    nonisolated enum Advance: Equatable {
        /// 上一步成功 → 启动下一步（下标）。
        case start(index: Int)
        /// 最后一步成功 → 链完成。
        case finished
        /// 停链（某步失败/取消；已成功步不回滚）。
        case stopped(reason: String)
    }

    static func advance(stepCount: Int, finishedStepIndex: Int, state: String) -> Advance {
        let lowered = state.lowercased()
        if lowered != "done" {
            return .stopped(reason: "step \(finishedStepIndex + 1) ended \(state)")
        }
        if finishedStepIndex + 1 >= stepCount {
            return .finished
        }
        return .start(index: finishedStepIndex + 1)
    }
}
