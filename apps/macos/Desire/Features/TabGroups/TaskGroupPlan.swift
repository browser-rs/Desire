import Foundation

/// 标签分组 v2（v0.8.10）：按"正在进行的事"聚合——一个任务的标签集合
/// （搜索/文档/工具页 + Agent 会话锚点）收进一个命名组。与既有两档的关系：
/// TabOrganizePlan 按站点 host、TabOrganizer.organizeByTopic 按模型主题；
/// 本档按**显式任务定义**（调用方给名字 + 标签 id 集合——UI 的多选、
/// Agent 的 groupTabs 工具、或"把当前研究收进一组"的快捷动作）。
/// 纯逻辑：归一化/校验/命名建议进 harness。
nonisolated enum TaskGroupPlan {

    /// 命名建议：从标签标题里挑信息量最大的词（去站点噪声），限 3 词 24 字。
    static func suggestedName(titles: [String], host: String = "") -> String {
        var words: [String] = []
        var seen = Set<String>()
        for title in titles {
            for token in title.split(whereSeparator: { " |·—-–()/[]".contains($0) }) {
                let w = token.trimmingCharacters(in: .whitespaces)
                guard w.count >= 2, w.count <= 20 else { continue }
                // 跳过站点通用词与纯数字
                let noise = ["https", "http", "www", "com", "cn", "net", "视频", "搜索",
                             "index", "html", "page", "登录", "首页"]
                guard !noise.contains(w.lowercased()), !w.allSatisfy(\.isNumber) else { continue }
                let key = w.lowercased()
                if seen.insert(key).inserted { words.append(w) }
                if words.count >= 3 { break }
            }
            if words.count >= 3 { break }
        }
        var name = words.joined(separator: " ")
        if name.isEmpty { name = host.isEmpty ? String(localized: "Task Group") : host }
        return String(name.prefix(24))
    }

    /// 建组校验：至少 2 个未分组标签、无重复 id；返回错误文案或 nil。
    static func validate(tabIDs: [UUID], alreadyGrouped: Set<UUID>) -> String? {
        let fresh = tabIDs.filter { !alreadyGrouped.contains($0) }
        if tabIDs.isEmpty { return String(localized: "No tabs selected") }
        if fresh.count < 2 { return String(localized: "Pick at least 2 ungrouped tabs") }
        if fresh.count != Set(fresh).count { return String(localized: "Duplicate tabs in selection") }
        return nil
    }

    /// 建组用的稳定色（按名字 hash，与 TabOrganizePlan 同算法——同名同色）。
    static func colorIndex(for name: String) -> Int {
        var hash = 5381
        for byte in name.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash) % 8
    }
}
