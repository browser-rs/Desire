import Foundation

/// Agent 模式（Loop 工程思想）：一个模式 = 工具子集 + 一句模式提示词。
/// 按窗口绑定（与人格/模型同款注册机制），标准模式不过滤任何工具——
/// 模式是"给模型划定的活动范围"，不是审批的替代（审批链独立于模式）。
/// Foundation-only：排除清单进 tests/run.sh。
nonisolated enum AgentMode: String, CaseIterable {
    case standard
    case research
    case writing

    var displayName: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .research: String(localized: "Research")
        case .writing: String(localized: "Writing")
        }
    }

    /// 本模式不提供给模型的工具（MCP 工具不受限）。子代理工具子集独立
    /// （子代理继承标准模式），排除 spawnSubagent 以防借道绕过。
    var excludedTools: Set<String> {
        switch self {
        case .standard:
            return []
        case .research:
            return ["executeJS", "runCommand", "fillLogin", "downloadMedia",
                    "startRecording", "stopRecording", "scheduleTask",
                    "cancelScheduledTask", "crewDispatch", "spawnSubagent"]
        case .writing:
            return ["runCommand", "fillLogin", "downloadMedia",
                    "startRecording", "stopRecording", "crewDispatch"]
        }
    }

    /// 系统提示里的模式说明（nil = 不注入该层）。
    var promptHint: String? {
        switch self {
        case .standard:
            return nil
        case .research:
            return "当前处于研究模式：以信息收集、核实与综合为主，变更性操作（执行代码、系统命令、下载、定时任务、子代理）不开放。"
        case .writing:
            return "当前处于写作模式：以内容创作为主（白板、文件、摘要、页面读取），系统命令与下载类操作不开放。"
        }
    }
}
