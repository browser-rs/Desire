import Foundation

/// 工具卡批量折叠纯逻辑（v0.8.31 批次三）：回合内连续同名工具调用
/// ≥3 次折叠为一行「name ×N」。进 tests/run.sh。
nonisolated enum ToolCallGrouper {

    struct Group: Equatable {
        let name: String
        let count: Int
        /// 在原数组里的下标区间（展开时还原原片段）。
        let range: Range<Int>

        var isCollapsed: Bool { count >= 3 }
    }

    /// 连续同名段分组（<3 次保持独立；恰好相邻两段同名被非同名隔开则各自成组）。
    static func group(_ names: [String]) -> [Group] {
        var groups: [Group] = []
        var index = 0
        while index < names.count {
            let name = names[index]
            var end = index + 1
            while end < names.count, names[end] == name {
                end += 1
            }
            let count = end - index
            if count >= 3 {
                groups.append(Group(name: name, count: count, range: index..<end))
            } else {
                for offset in index..<end {
                    groups.append(Group(name: name, count: 1, range: offset..<offset + 1))
                }
            }
            index = end
        }
        return groups
    }
}
