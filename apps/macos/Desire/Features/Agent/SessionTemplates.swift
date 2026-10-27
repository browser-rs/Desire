import Foundation

/// 会话模板（v0.8.13 基础件 7）：常用任务的提示词骨架——slash 菜单
/// `/templates` 一键套用（预填目标/约束/输出格式）。与 skills 的分界：
/// 模板 = 提示词骨架（{{变量}} 占位），技能 = 操作剧本（工具编排）。
/// 内置模板 + 用户自定义（UserDefaults，JSON）。Foundation-only，进 harness。
nonisolated enum SessionTemplates {

    struct Template: Codable, Equatable, Identifiable {
        var name: String
        var descriptionText: String
        /// 骨架文本，支持 {{变量}} 占位（套用时逐个询问/由参数填充）。
        var body: String
        var builtin: Bool = false
        var id: String { name }
    }

    static let builtins: [Template] = [
        Template(
            name: "weekly-report",
            descriptionText: String(localized: "Weekly report skeleton"),
            body: """
            写本周周报。
            本周完成：{{完成事项，用分号分隔}}
            数据亮点：{{关键数据}}
            输出格式：三段式（进展 / 数据 / 下周计划），每段不超过 5 行，中文。
            """,
            builtin: true),
        Template(
            name: "translate-doc",
            descriptionText: String(localized: "Translate a passage with constraints"),
            body: """
            翻译下面的内容为{{目标语言，如英文}}。
            术语表：{{术语对，格式"原文=译文"，分号分隔}}
            要求：保留专有名词与数字；语气{{语气，如正式/口语}}；不解释，只输出译文。
            ---
            {{正文}}
            """,
            builtin: true),
        Template(
            name: "price-compare",
            descriptionText: String(localized: "Price comparison skeleton"),
            body: """
            对比以下{{数量}}个商品的{{维度，如价格/保修/评分}}：
            {{商品清单，每行一个}}
            用表格输出对比结果，最后一行给出推荐与理由（不超过两行）。
            """,
            builtin: true),
    ]

    private static let customKey = "desire.sessionTemplates"

    // MARK: - 读取/保存

    static func all() -> [Template] {
        var list = builtins
        list.append(contentsOf: custom())
        return list
    }

    static func custom() -> [Template] {
        guard let data = UserDefaults.standard.data(forKey: customKey) else { return [] }
        return (try? JSONDecoder().decode([Template].self, from: data)) ?? []
    }

    static func saveCustom(_ templates: [Template]) {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }

    static func addCustom(_ template: Template) {
        var list = custom().filter { $0.name != template.name }
        list.append(template)
        saveCustom(list)
    }

    static func removeCustom(name: String) {
        var list = custom()
        list.removeAll { $0.name == name }
        saveCustom(list)
    }

    // MARK: - 纯逻辑（进 harness）

    /// 骨架里的 {{变量}} 名（去重，按出现顺序）。
    nonisolated static func variables(in body: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var rest = Substring(body)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            let rawName = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            rest = rest[close.upperBound...]
            guard !rawName.isEmpty, seen.insert(rawName).inserted else { continue }
            out.append(rawName)
        }
        return out
    }

    /// 套用：按字典替换 {{变量}}；未提供的变量保留原样（用户可手补）。
    nonisolated static func render(_ body: String, values: [String: String]) -> String {
        var result = body
        for (name, value) in values {
            result = result.replacingOccurrences(
                of: "{{\(name)}}",
                with: value,
                options: .literal)
        }
        return result
    }
}
