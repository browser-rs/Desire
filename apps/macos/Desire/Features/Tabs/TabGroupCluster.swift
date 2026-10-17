import Foundation

/// 标签页语义聚类的**解析与校验**（v0.7.20 `autoGroupTabs` 的纯逻辑层，
/// Foundation-only 进 tests/run.sh）。
///
/// 模型只要给「组名 + 标签下标」的 JSON；这里负责把不可信输出收干净：
/// 剥代码围栏/前后杂讯、下标越界剔除、每个下标只归一组（先到先得）、
/// 重名组加序号、空组丢弃、组名截断——**宁可少分组也不误归位**。
enum TabGroupCluster {

    struct Group: Equatable {
        let name: String
        let titleIndices: [Int]
    }

    struct Plan: Equatable {
        let groups: [Group]
    }

    static let maxGroups = 6
    static let maxNameLength = 16

    /// 解析模型输出；没有任何可用分组返回 nil（调用方如实报失败）。
    static func parse(_ raw: String, tabCount: Int, maxGroups: Int = TabGroupCluster.maxGroups) -> Plan? {
        guard tabCount > 1 else { return nil }
        // 剥 ```json 围栏与前置说明：取第一个 { 到最后一个 } 的片段。
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        } else {
            return nil
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawGroups = object["groups"] as? [[String: Any]] else {
            return nil
        }

        var usedIndices = Set<Int>()
        var usedNames = Set<String>()
        var groups: [Group] = []
        for rawGroup in rawGroups {
            guard groups.count < maxGroups else { break }
            guard var name = (rawGroup["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            name = String(name.prefix(maxNameLength))
            // 重名加序号（沿用已有同名组语义由调用方处理；这里只保证批内唯一）。
            var candidate = name
            var suffix = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(name) \(suffix)"
                suffix += 1
            }
            let indicesRaw = (rawGroup["indices"] as? [Any]) ?? []
            var indices: [Int] = []
            for value in indicesRaw {
                let number: Int?
                if let n = value as? Int { number = n }
                else if let n = value as? NSNumber { number = n.intValue }
                else if let s = value as? String { number = Int(s.trimmingCharacters(in: .whitespaces)) }
                else { number = nil }
                guard let idx = number, tabCount > idx, idx >= 0, !usedIndices.contains(idx) else { continue }
                usedIndices.insert(idx)
                indices.append(idx)
            }
            guard indices.count >= 2 else { continue }   // 单标签组没意义：丢弃
            usedNames.insert(candidate.lowercased())
            groups.append(Group(name: candidate, titleIndices: indices.sorted()))
        }
        guard !groups.isEmpty else { return nil }
        return Plan(groups: groups)
    }
}
