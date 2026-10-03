import Foundation

/// 白板数据模型（§一期）：一块白板 = 有序的块列表。智能体与页面
/// 都只产出**结构化描述**（Mermaid 源码 / ECharts 配置 / Markdown），
/// 渲染交给本地双引擎——这是"白板 = 结构化数据的渲染器"的落点。
struct WhiteboardSpec: Codable, Equatable {
    var title: String
    var blocks: [WhiteboardBlock]

    init(title: String = "白板", blocks: [WhiteboardBlock] = []) {
        self.title = title
        self.blocks = blocks
    }
}

/// 白板块。`content` 的语义随 `type`：
/// - `.mermaid`：Mermaid 源码（flowchart/mindmap/sequence/gantt…）
/// - `.chart`：ECharts option 的 JSON 字符串（对象在工具入口就序列化）
/// - `.note`：Markdown 文本
struct WhiteboardBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var type: String
    var title: String?
    var content: String

    enum Kind {
        static let mermaid = "mermaid"
        static let chart = "chart"
        static let note = "note"
        static let table = "table"
    }

    init(id: UUID = UUID(), type: String, title: String? = nil, content: String) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
    }

    var isValid: Bool {
        guard [WhiteboardBlock.Kind.mermaid, WhiteboardBlock.Kind.chart,
               WhiteboardBlock.Kind.note, WhiteboardBlock.Kind.table].contains(type) else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 块管理变换（纯函数，供面板编辑与单测）

extension WhiteboardSpec {
    func movingBlock(_ index: Int, delta: Int) -> WhiteboardSpec {
        var spec = self
        let target = index + delta
        guard blocks.indices.contains(index), blocks.indices.contains(target) else { return self }
        spec.blocks.swapAt(index, target)
        return spec
    }

    func deletingBlock(_ index: Int) -> WhiteboardSpec {
        var spec = self
        guard blocks.indices.contains(index) else { return self }
        spec.blocks.remove(at: index)
        return spec
    }

    func editingBlock(_ index: Int, content: String) -> WhiteboardSpec {
        var spec = self
        guard blocks.indices.contains(index) else { return self }
        spec.blocks[index].content = content
        return spec
    }
}
