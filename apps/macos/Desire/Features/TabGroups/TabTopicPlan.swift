import Foundation

/// 模型驱动的标签主题分组计划（v0.8.1，纯逻辑，进 harness）。
///
/// 模型只返回 `[{"name": "...", "tabs": [0, 2]}]`（下标对应发给它的候选
/// 列表）。这里做**严格校验**：下标越界、跨组重复、单标签组、空名、超长名
/// 一律丢弃——模型输出不可信，绝不拿未校验的下标去动标签。
nonisolated enum TabTopicPlan {
    struct Group: Equatable {
        let name: String
        let tabIDs: [UUID]
    }

    static func parse(_ raw: String, tabIDs: [UUID],
                      maxGroups: Int = 8) -> [Group] {
        guard let json = extractJSONArray(from: raw),
              let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var used = Set<Int>()
        var groups: [Group] = []
        for row in rows {
            guard groups.count < maxGroups else { break }
            guard let rawName = row["name"] as? String else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 40 else { continue }
            guard let indices = row["tabs"] as? [Int] else { continue }
            var ids: [UUID] = []
            var added = Set<Int>()
            for index in indices {
                guard index >= 0, index < tabIDs.count,
                      !used.contains(index) else { continue }
                used.insert(index)
                added.insert(index)
                ids.append(tabIDs[index])
            }
            guard ids.count >= 2 else {
                // 本组不足两个有效标签 → 回滚本组占据的下标，留给后面的组。
                for index in added { used.remove(index) }
                continue
            }
            groups.append(Group(name: name, tabIDs: ids))
        }
        return groups
    }

    /// 从模型回复里抠出第一个 JSON 数组（容忍 ```json 围栏与前后说明文字）。
    static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end else { return nil }
        return String(text[start...end])
    }

    /// 分组名的稳定颜色（与站点分组同一套 0–7 色板）。
    static func colorIndex(for name: String) -> Int {
        var hash = 5381
        for byte in name.lowercased().utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash) % 8
    }
}
