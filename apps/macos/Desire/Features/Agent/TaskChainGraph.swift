import Foundation

/// 任务链的只读拓扑（v0.8.81 批 6）：从某个任务往后走出完整路径、找上游、
/// 判是否有环。纯逻辑（Foundation-only），调度器用它做"从这一步继续"与
/// 面板全链预览；真正的防环写入仍在 `AgentScheduler.setChain`。
nonisolated enum TaskChainGraph {
    struct Node: Equatable, Sendable {
        let name: String
        let chainTo: String?

        init(name: String, chainTo: String?) {
            self.name = name
            self.chainTo = chainTo
        }
    }

    /// 从 `startingAt` 起沿 `chainTo` 走，最多 `maxDepth` 个节点；遇未知节点
    /// 或环即停（环时最后一个节点不会重复追加）。
    static func path(startingAt: String, nodes: [Node], maxDepth: Int = 20) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var current: String? = startingAt
        while let name = current, !name.isEmpty, !seen.contains(name), out.count < maxDepth {
            seen.insert(name)
            out.append(name)
            current = nodes.first(where: { $0.name == name })?.chainTo
        }
        return out
    }

    /// 直接上游：谁的 chainTo 指向 `name`。多条入边时取定义顺序的第一条
    /// （链是单前驱的便利语义；真正分叉应由用户显式建两条任务）。
    static func predecessor(of name: String, nodes: [Node]) -> String? {
        nodes.first(where: { $0.chainTo == name })?.name
    }

    /// 图里是否存在环（每个节点走一遍；自指也算）。
    static func hasCycle(nodes: [Node]) -> Bool {
        var map: [String: String] = [:]
        for node in nodes where map[node.name] == nil {
            if let next = node.chainTo { map[node.name] = next }
        }
        for node in nodes {
            var seen = Set<String>()
            var current: String? = node.name
            while let name = current {
                if !seen.insert(name).inserted { return true }
                current = map[name] ?? nil
            }
        }
        return false
    }
}
