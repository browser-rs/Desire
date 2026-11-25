import Foundation

/// **回合推进度量**（v0.8.76 批 1，Foundation-only 进 tests/run.sh）。
///
/// 回合里的每一步工具调用归为三类：
/// - `observe` 查看——不改变任何状态（只读工具）：读页面、列进度、取结果切片；
/// - `act` 动作——改变了什么：启动下载、导航、写文件、订阅完成通知……；
/// - `neutral` 中性——既不是查看也不是任务动作：加载技能、更新计划、向用户
///   提问、等待类。它们不该被算成"探索"，也不算"推进"。
///
/// 用途：量"首个有效动作之前探索了几步""多少个请求是纯查看""同一个结果看了
/// 几遍"。这是重复任务熟练度的验收尺；回合内打转护栏复用同一套分类——
/// 保证"量出来的"和"管起来的"是同一件事。
nonisolated enum TurnProgress {

    enum StepKind: Equatable, Sendable {
        case observe, act, neutral
    }

    struct Step: Equatable, Sendable {
        let tool: String
        let arguments: String
        /// 工具结果的开头（调用方已截断；只用于判断"是不是同一个结果"）。
        let result: String
    }

    /// 既不算查看也不算动作的工具。
    /// - `useSkill` 在只读工具表里，但它是"把做法装进来"，不是探索页面；`useTools`
    ///   （按需加载工具定义）同理；
    /// - `updatePlan` / `askUser` / `reflect` 是编排与沟通；
    /// - 等待类是"等"不是"看"——烧的是时间不是请求，单独归中性。
    static let neutralTools: Set<String> = [
        "useSkill", "useTools", "resolveVideos", "updatePlan", "askUser", "reflect",
        "wait", "waitForText", "waitForSelector", "waitForElement", "waitForDownload",
    ]

    /// 进度查询——"看一眼好了没"的查看子类。长任务启动后的轮询都在这里。
    static let progressQueryTools: Set<String> = [
        "listBatchDownloads", "listBackgroundTasks", "backgroundTaskStatus",
        "listMediaExports", "listDownloads",
    ]

    /// 比较两次查看是否"同一个结果"时取的长度。进度类结果开头通常含计数与
    /// 百分比，状态变了开头就变；取太长会被尾部的耗时/时间戳干扰。
    static let resultCompareLength = 200

    static func kind(of tool: String) -> StepKind {
        if neutralTools.contains(tool) { return .neutral }
        return ToolRisk.classify(tool) == .readonly ? .observe : .act
    }

    static func isObservation(tool: String) -> Bool { kind(of: tool) == .observe }

    /// 一批工具调用是否构成"纯查看请求"——有调用，且全是查看。
    static func isPureObservationRequest(tools: [String]) -> Bool {
        !tools.isEmpty && tools.allSatisfy(isObservation)
    }

    struct Summary: Equatable, Sendable {
        var steps = 0
        var observations = 0
        var actions = 0
        var neutral = 0
        /// 查看里属于进度查询的步数。
        var progressQueries = 0
        /// 首个动作之前的查看步数。回合里没有动作 = nil（纯问答或全程没推进）。
        var exploreBeforeFirstAction: Int?
        /// 同一查看工具在本回合里的第 2 次及以后（不看参数）——"又去看同一个东西"。
        /// 这是主指标：真实轨迹里"反复查看"绝大多数是换个参数再看（再执行一个
        /// 解析脚本、再查一遍目录、再读一片结果），一字不差的重看只占极少数。
        var repeatToolObservations = 0
        /// 单个查看工具在本回合里的最大调用次数。
        var maxSameToolObservations = 0
        /// 同一（工具, 参数）再次查看且结果开头相同——纯重复（细分）。
        var repeatedSameResult = 0
        /// 同一（工具, 参数）再次查看但结果变了——在等状态变化（细分）。
        var repeatedChangedResult = 0
        /// 结尾处连续的查看步数：回合以一串查看收尾 = 看完没动手就结束。
        var trailingObservations = 0
    }

    static func summarize(_ steps: [Step]) -> Summary {
        var summary = Summary()
        summary.steps = steps.count
        var lastResult: [String: String] = [:]
        var perTool: [String: Int] = [:]
        var sawAction = false
        for step in steps {
            switch kind(of: step.tool) {
            case .observe:
                summary.observations += 1
                summary.trailingObservations += 1
                if progressQueryTools.contains(step.tool) { summary.progressQueries += 1 }
                let seen = (perTool[step.tool] ?? 0) + 1
                perTool[step.tool] = seen
                if seen >= 2 { summary.repeatToolObservations += 1 }
                summary.maxSameToolObservations = max(summary.maxSameToolObservations, seen)
                let head = String(step.result.prefix(resultCompareLength))
                let key = step.tool + "\u{1}" + step.arguments
                if let previous = lastResult[key] {
                    if previous == head { summary.repeatedSameResult += 1 }
                    else { summary.repeatedChangedResult += 1 }
                }
                lastResult[key] = head
            case .act:
                summary.actions += 1
                summary.trailingObservations = 0
                // 首个动作发生的那一刻记下"之前看了几眼"：开局即动作 = 0；
                // 整个回合没有动作则保持 nil（没有"首个动作前"可言）。
                if !sawAction { summary.exploreBeforeFirstAction = summary.observations }
                sawAction = true
            case .neutral:
                summary.neutral += 1
            }
        }
        return summary
    }

    /// 轨迹 JSON 里的投影（桥与评估脚本读这一份）。
    static func dictionary(_ summary: Summary) -> [String: Any] {
        var out: [String: Any] = [
            "steps": summary.steps,
            "observations": summary.observations,
            "actions": summary.actions,
            "neutral": summary.neutral,
            "progressQueries": summary.progressQueries,
            "repeatToolObservations": summary.repeatToolObservations,
            "maxSameToolObservations": summary.maxSameToolObservations,
            "repeatedSameResult": summary.repeatedSameResult,
            "repeatedChangedResult": summary.repeatedChangedResult,
            "trailingObservations": summary.trailingObservations,
        ]
        if let explore = summary.exploreBeforeFirstAction { out["exploreBeforeFirstAction"] = explore }
        return out
    }
}
