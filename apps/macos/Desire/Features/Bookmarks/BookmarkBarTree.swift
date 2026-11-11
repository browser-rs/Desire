import Foundation

/// 书签栏的纯渲染/布局逻辑（v0.8.53 书签 2.0）：树构建、容量分割（放不下的
/// 收进「更多」溢出菜单）、"打开全部"的叶子收集。Foundation-only、进
/// tests/run.sh——栏视图只负责画，不内联任何树形逻辑。
nonisolated enum BookmarkBarTree {
    struct Node: Identifiable, Equatable {
        let id: UUID
        let title: String
        let url: String?
        let isFolder: Bool
        let children: [Node]

        var leafCount: Int {
            isFolder ? children.reduce(0) { $0 + $1.leafCount } : 1
        }
    }

    /// 顶层书签/文件夹 → 栏节点（递归）；叶子取标题，空标题回退 host。
    static func build(_ tree: [Bookmark]) -> [Node] {
        tree.map { node in
            Node(id: node.id,
                 title: displayTitle(node),
                 url: node.url,
                 isFolder: node.isFolder,
                 children: node.isFolder ? build(node.children) : [])
        }
    }

    static func displayTitle(_ bookmark: Bookmark) -> String {
        let trimmed = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !bookmark.isFolder, let url = bookmark.url {
            if let host = URL(string: url)?.host { return host }
            return url
        }
        return "Untitled"
    }

    /// 文件夹的"打开全部"：递归收集全部叶子 URL（顺序 = 树顺序）。
    static func leafURLs(_ node: Node) -> [String] {
        if !node.isFolder {
            return node.url.map { [$0] } ?? []
        }
        return node.children.flatMap(leafURLs)
    }

    // MARK: - 容量分割

    static let itemChromeWidth: CGFloat = 34   // 图标 + 内边距
    static let folderChromeWidth: CGFloat = 18 // 折叠箭头
    static let overflowReserveWidth: CGFloat = 96 // 「更多书签 ⌄」按钮
    static let separatorWidth: CGFloat = 9
    static let maxTitleWidth: CGFloat = 170

    /// 栏上单项的估算宽度（字符数 × 字宽，标题超长截断到 maxTitleWidth）。
    static func estimatedWidth(_ node: Node) -> CGFloat {
        let charCount = min(CGFloat(node.title.count) * 7.0, maxTitleWidth)
        let base = itemChromeWidth + max(28, charCount)
        return node.isFolder ? base + folderChromeWidth : base
    }

    struct Split: Equatable {
        let visible: [Node]
        let overflow: [Node]
    }

    /// 按可用宽度把节点切成"直接展示"与"溢出菜单"两段。
    /// 口径：溢出按钮常驻（reserve 计入预算）；单项间加分隔线；一个都放不下
    /// 时 visible 为空、全部进溢出（窄窗下栏只显示「更多书签」）。
    static func split(nodes: [Node], availableWidth: CGFloat) -> Split {
        let budget = max(0, availableWidth - overflowReserveWidth)
        var used: CGFloat = 0
        var visible: [Node] = []
        var overflow: [Node] = []
        for node in nodes {
            let width = estimatedWidth(node) + (visible.isEmpty ? 0 : separatorWidth)
            if used + width <= budget, overflow.isEmpty {
                used += width
                visible.append(node)
            } else {
                overflow.append(node)
            }
        }
        return Split(visible: visible, overflow: overflow)
    }
}
