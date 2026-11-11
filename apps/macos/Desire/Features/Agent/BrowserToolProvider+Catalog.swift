import Foundation

/// `listTools` 元工具（v0.8.51 批 1）：按需展开工具目录。
///
/// 系统提示词里只放**分组摘要**（组名 + 数量 + 代表），模型不确定工具名或参数时
/// 调这里拿完整定义（描述 + 参数名/类型/是否必填）。无参调用 = 列出所有组。
extension BrowserToolProvider {
    static func listToolsTool(_ args: [String: Any]) -> String {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let groupArg = (args["group"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(40, max(1, Int(args["limit"] as? Double ?? 15)))
        let defs = BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs
        let mcpNames = Set(MCPStore.shared.toolDefs.map { $0.function.name })

        // 无参：列出所有组与代表工具（与提示词摘要同源）。
        if query.isEmpty && groupArg.isEmpty {
            let inventory = defs.map { (name: $0.function.name, summary: "") }
            let summaries = AgentToolCatalog.groups(inventory, mcpNames: mcpNames)
            let lines = summaries.map { summary -> String in
                "- \(summary.group.rawValue) (\(summary.count)): "
                    + summary.samples.joined(separator: ", ")
                    + (summary.count > summary.samples.count ? ", …" : "")
            }
            return "Tool groups — call listTools with group=<name> or query=<words> to expand:\n"
                + lines.joined(separator: "\n")
        }

        let targetGroup: AgentToolGroup? = {
            guard !groupArg.isEmpty else { return nil }
            let normalized = groupArg.lowercased()
            if let direct = AgentToolGroup(rawValue: normalized.replacingOccurrences(of: " ", with: "")) {
                return direct
            }
            return AgentToolGroup.allCases.first {
                $0.title.lowercased().contains(normalized) || normalized.contains($0.title.lowercased())
            }
        }()
        if !groupArg.isEmpty, targetGroup == nil {
            let names = AgentToolGroup.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown group \"\(groupArg)\". Available: \(names)"
        }

        let words = query.lowercased().split(separator: " ").map(String.init)
        func nameTokens(_ name: String) -> String {
            // readFile → "read file"：按驼峰拆词，查询词按词边界命中。
            var out = ""
            for character in name {
                if character.isUppercase, !out.isEmpty { out.append(" ") }
                out.append(Character(character.lowercased()))
            }
            return out
        }
        func nameHit(_ def: AgentToolDef) -> Bool {
            guard !words.isEmpty else { return false }
            let tokens = nameTokens(def.function.name)
            return words.allSatisfy { tokens.contains($0) }
        }
        let matches = defs.filter { def in
            if let targetGroup {
                let group = AgentToolCatalog.classify(
                    name: def.function.name,
                    isMCP: mcpNames.contains(def.function.name))
                guard group == targetGroup else { return false }
            }
            guard !words.isEmpty else { return true }
            let haystack = (def.function.name + " " + def.function.description).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.sorted { a, b in
            let aHit = nameHit(a)
            let bHit = nameHit(b)
            if aHit != bHit { return aHit }
            return a.function.name < b.function.name
        }

        guard !matches.isEmpty else {
            return "No tools matched \"\(query)\"\(groupArg.isEmpty ? "" : " in group \(groupArg)"). "
                + "Try fewer words, or call listTools with no arguments to see the groups."
        }
        let shown = matches.prefix(limit)
        var lines = shown.map { AgentToolCatalog.describe($0) }
        if matches.count > shown.count {
            lines.append("…\(matches.count - shown.count) more matched — narrow the query or raise limit (max 40).")
        }
        return lines.joined(separator: "\n\n")
    }
}
