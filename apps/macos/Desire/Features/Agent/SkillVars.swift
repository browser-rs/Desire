import Foundation

/// 技能参数槽位（v0.8.17 Agent 基础）：SKILL.md frontmatter 声明变量、
/// 正文 {{name}} 占位，运行时填值。约定（平铺行式，避开 YAML 嵌套）：
///
///     ---
///     name: weekly-report
///     vars: target, week
///     var-week-default: 本周
///     var-target-desc: 汇报对象
///     ---
///     给 {{target}} 的 {{week}} 周报……
///
/// Foundation-only，进 tests/run.sh。
nonisolated enum SkillVars {

    struct Var: Equatable {
        let name: String
        let defaultValue: String?
        let description: String?
    }

    /// 取 frontmatter 块（不含围栏行）；无 frontmatter 返回 nil。
    nonisolated static func frontmatterBlock(_ text: String) -> String? {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---") else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound])
    }

    /// 解析 vars 声明与 var-<name>-default/desc 修饰行。
    nonisolated static func parse(frontmatter: String) -> [Var] {
        var names: [String] = []
        var defaults: [String: String] = [:]
        var descriptions: [String: String] = [:]
        for rawLine in frontmatter.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("vars:") {
                names = line.dropFirst("vars:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if line.hasPrefix("var-") {
                let rest = line.dropFirst("var-".count)
                if let defaultRange = rest.range(of: "-default:") {
                    defaults[String(rest[..<defaultRange.lowerBound])] =
                        String(rest[defaultRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else if let descRange = rest.range(of: "-desc:") {
                    descriptions[String(rest[..<descRange.lowerBound])] =
                        String(rest[descRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return names.map { name in
            Var(name: name, defaultValue: defaults[name], description: descriptions[name])
        }
    }

    /// 从全文解析（frontmatterBlock + parse 组合）。
    nonisolated static func parse(_ text: String) -> [Var] {
        guard let block = frontmatterBlock(text) else { return [] }
        return parse(frontmatter: block)
    }

    /// 正文里的 {{name}} 占位名（去重保序）。
    nonisolated static func placeholders(in body: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var rest = Substring(body)
        while let start = rest.range(of: "{{") {
            guard let end = rest[start.upperBound...].range(of: "}}") else { break }
            let name = String(rest[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            rest = rest[end.upperBound...]
            guard !name.isEmpty, !name.contains(" "), !name.contains("\n"),
                  seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// {{name}} 替换：values 命中 → 值；未命中 → 原样保留（模型可见缺失）。
    nonisolated static func render(body: String, values: [String: String]) -> String {
        placeholders(in: body).reduce(body) { current, name in
            guard let value = values[name], !value.isEmpty else { return current }
            return current.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
    }

    /// 缺失清单：声明了 vars、占位符存在、values 与默认值都没有的名字。
    nonisolated static func missing(declared: [Var], values: [String: String],
                                    body: String) -> [String] {
        let placeholders = placeholders(in: body)
        return declared
            .filter { var_ in
                placeholders.contains(var_.name)
                    && (values[var_.name] ?? var_.defaultValue ?? "").isEmpty
            }
            .map(\.name)
    }
}
