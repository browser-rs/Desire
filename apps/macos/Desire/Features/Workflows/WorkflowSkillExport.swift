import Foundation

/// 工作流 → 技能转换（v0.8.20 旗舰）：录制的回放步骤序列转 SKILL.md——
/// 每步转自然语言指令（选择器/等待/导航），敏感字段转 {{vars}}（值绝不
/// 落盘的口径在技能里延续为"运行时填值"）。转换是单向生成：SKILL.md
/// 手改后不回写工作流。
/// Foundation-only，进 tests/run.sh。
nonisolated enum WorkflowSkillExport {

    struct Result: Equatable {
        var fileName: String   // SkillStore 目录内的落点名
        var markdown: String
        var varNames: [String]
    }

    /// 步骤 → 指令行。selectors 首个候选优先；text: 前缀转"可见文本"。
    nonisolated static func stepInstruction(_ step: Workflow.Step, index: Int) -> String {
        let selector = step.selectors.first ?? ""
        let readable: String
        if selector.hasPrefix("text:") {
            readable = "可见文本为「\(String(selector.dropFirst(5)))」的元素"
        } else if !selector.isEmpty {
            readable = "`\(selector)`"
        } else {
            readable = "目标元素"
        }
        switch step.kind {
        case .navigate:
            return "\(index + 1). navigate 到 `\(step.url ?? "")`"
        case .click:
            return "\(index + 1). click \(readable)"
        case .input:
            let value = step.value ?? "{{\(fieldName(step, index: index))}}"
            return "\(index + 1). fill \(readable) 为 `\(value)`"
        case .select:
            let value = step.value ?? "{{\(fieldName(step, index: index))}}"
            return "\(index + 1). 在 \(readable) 下拉中选 `\(value)`"
        case .key:
            return "\(index + 1). pressKey \(readable)"
        case .waitFor:
            return "\(index + 1). waitForText `\(step.value ?? step.selectors.first ?? "")`（页面就绪信号）"
        }
    }

    /// 敏感输入的变量名（step.note 优先——录制时的人类说明最达意）。
    nonisolated static func fieldName(_ step: Workflow.Step, index: Int) -> String {
        let note = (step.note ?? "").trimmingCharacters(in: .whitespaces)
        if !note.isEmpty, note.count <= 16, !note.contains(" ") {
            return note
        }
        return "field\(index + 1)"
    }

    /// 整份 SKILL.md：frontmatter（name/description/vars）+ 流程体。
    nonisolated static func markdown(for workflow: Workflow) -> Result {
        var varNames: [String] = []
        var varDecls: [String] = []
        var body = """
        ## 流程
        1. navigate 到 `\(workflow.startURL)`（\(workflow.host)）。

        """
        for (index, step) in workflow.steps.enumerated() {
            body += stepInstruction(step, index: index) + "\n"
            if step.sensitive, step.kind == .input || step.kind == .select {
                let name = fieldName(step, index: index)
                if !varNames.contains(name) {
                    varNames.append(name)
                    varDecls.append("var-\(name)-desc: \(step.note ?? "敏感字段，运行时填入")")
                }
            }
        }
        body += """
        ## 规则
        - 敏感字段（密码/卡号/验证码）由用户运行时提供，绝不写入文件或日志。
        - 本技能由工作流「\(workflow.name)」转换生成；选择器失效时用 getFormFields/findElements 重新定位。

        """
        var frontmatter = "---\nname: \(workflow.name)\ndescription: 由工作流转换：\(workflow.host) 上的「\(workflow.name)」流程（\(workflow.steps.count) 步）\n"
        if !varNames.isEmpty {
            frontmatter += "vars: \(varNames.joined(separator: ", "))\n"
            for decl in varDecls {
                frontmatter += decl + "\n"
            }
        }
        frontmatter += "---\n"
        let slug = workflow.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return Result(fileName: "\(slug).md",
                      markdown: frontmatter + "\n" + body,
                      varNames: varNames)
    }
}
