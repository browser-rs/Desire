import Foundation

/// 从 Agent 轨迹回合提炼工作流草稿（v0.7.29）：只认 navigate/click/fill，
/// 其它工具忽略；fill 的字段名命中敏感词时值不落盘（回放时现填）。
/// 纯逻辑（Foundation-only，进 harness）。
nonisolated enum WorkflowDistill {
    struct Draft: Equatable {
        var name: String
        var host: String
        var startURL: String
        var steps: [Workflow.Step]
    }

    /// turn 是 `AgentTrace.turns` 的一行（steps: action/args/...）。
    /// 没有 navigate 步骤就没有可靠起点 → nil（不生成无法回放的草稿）。
    static func draft(fromTurn turn: [String: Any], name: String = "") -> Draft? {
        let rawSteps = (turn["steps"] as? [[String: Any]]) ?? []
        var steps: [Workflow.Step] = []
        var startURL: String?
        var host: String?

        for raw in rawSteps {
            guard let action = raw["action"] as? String,
                  let argsText = raw["args"] as? String,
                  let data = argsText.data(using: .utf8),
                  let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            switch action {
            case "navigate":
                guard let url = args["url"] as? String, !url.isEmpty else { continue }
                if startURL == nil {
                    startURL = url
                    host = WorkflowLogic.host(of: url)
                }
                steps.append(.init(kind: .navigate, url: url,
                                   note: String(url.prefix(120))))
            case "click":
                var selectors: [String] = []
                if let selector = args["selector"] as? String, !selector.isEmpty {
                    selectors.append(selector)
                }
                if let text = args["text"] as? String, !text.isEmpty {
                    selectors.append("text:" + text)
                }
                guard selectors.contains(where: WorkflowLogic.isValidSelector) else { continue }
                let note = (args["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? selectors.first
                steps.append(.init(kind: .click, selectors: selectors, note: note))
            case "fill":
                guard let selector = args["selector"] as? String, !selector.isEmpty else { continue }
                let rawValue = args["value"] as? String ?? ""
                let sensitive = WorkflowLogic.isSensitiveField(
                    type: nil, autocomplete: nil,
                    name: selector, id: nil, placeholder: nil)
                steps.append(.init(kind: .input,
                                   selectors: [selector],
                                   value: sensitive ? nil : String(rawValue.prefix(500)),
                                   sensitive: sensitive,
                                   note: selector))
            default:
                continue
            }
        }

        guard let startURL, let host, !steps.isEmpty else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Workflow \(steps.count) step(s)" : name
        return Draft(name: title, host: host, startURL: startURL, steps: steps)
    }

    static func workflow(from draft: Draft, now: Date = Date()) -> Workflow {
        Workflow(name: draft.name, host: draft.host, startURL: draft.startURL,
                 createdAt: now, updatedAt: now, steps: draft.steps)
    }
}
