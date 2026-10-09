import Foundation

/// 技能自沉淀（saveSkill 工具）的**纯逻辑半边**：把模型交来的字段渲染成
/// SKILL.md（frontmatter name/description 与 SkillStore.parse 同构）。
/// Foundation-only：进 tests/run.sh 回归。落盘与 reload 在工具执行侧。
nonisolated enum SkillAuthoring {
    static func markdown(name: String, description: String, instructions: String) -> String {
        var body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正文若自带 frontmatter，剥掉——权威 frontmatter 由这里重新生成，
        // 避免嵌套两段 "---" 让解析器认错。
        if body.hasPrefix("---"), let end = body.range(of: "\n---") {
            body = String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
        ---
        name: \(name.trimmingCharacters(in: .whitespacesAndNewlines))
        description: \(description.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
        ---
        \(body)
        """
    }
}
