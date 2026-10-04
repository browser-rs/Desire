import Foundation

/// 白板数据模型（§一期）：一块白板 = 有序的块列表。智能体与页面
/// 都只产出**结构化描述**（Mermaid 源码 / ECharts 配置 / Markdown），
/// 渲染交给本地双引擎——这是"白板 = 结构化数据的渲染器"的落点。
struct WhiteboardSpec: Codable, Equatable {
    var title: String
    var blocks: [WhiteboardBlock]

    /// 一块板的块数上限（工具层护栏）：renderBoard 逐块渲染，块数失控
    /// 会把双引擎渲染与 DiskStore 落盘一起拖垮。面板编辑不受此限。
    static let maxBlocks = 60

    init(title: String = "白板", blocks: [WhiteboardBlock] = []) {
        self.title = title
        self.blocks = blocks
    }
}

/// 白板块。`content` 的语义随 `type`：
/// - `.mermaid`：Mermaid 源码（flowchart/mindmap/sequence/gantt…）
/// - `.chart`：ECharts option 的 JSON 字符串（对象在工具入口就序列化）
/// - `.note`：Markdown 文本
/// - `.image`：`data:image/…` URI（base64）——截图/图片上板（远程 URL 不收，
///   免得板内容依赖网络与页面来源）
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
        static let image = "image"
    }

    /// image 块的内容上限（data URI 字符数 ≈ 8MB 二进制）——防止一次截图
    /// 把 DiskStore 落盘与 .board JSON 撑爆。
    static let maxImageContentChars = 11_000_000

    init(id: UUID = UUID(), type: String, title: String? = nil, content: String) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
    }

    var isValid: Bool {
        guard [WhiteboardBlock.Kind.mermaid, WhiteboardBlock.Kind.chart,
               WhiteboardBlock.Kind.note, WhiteboardBlock.Kind.table,
               WhiteboardBlock.Kind.image].contains(type) else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == WhiteboardBlock.Kind.image {
            return trimmed.hasPrefix("data:image/") && content.count <= Self.maxImageContentChars
        }
        return !trimmed.isEmpty
    }

    /// 从工具/桥的原始字典构造（content 接受字符串或对象——chart 的
    /// ECharts option 常被模型给成 JSON 对象，这里统一序列化）。
    /// 非法返回 nil（类型缺失/内容缺失/序列化失败），由调用方计数跳过。
    static func make(from item: [String: Any]) -> WhiteboardBlock? {
        guard let type = item["type"] as? String else { return nil }
        var content: String
        if let text = item["content"] as? String {
            content = text
        } else if let object = item["content"] {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            content = text
        } else {
            return nil
        }
        let block = WhiteboardBlock(type: type, title: item["title"] as? String, content: content)
        return block.isValid ? block : nil
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

    /// 拖拽排序：把 from 位置的块移到 to 位置（0-based，其余块顺移）。
    func reorderingBlock(from: Int, to: Int) -> WhiteboardSpec {
        var spec = self
        guard blocks.indices.contains(from), blocks.indices.contains(to), from != to else { return self }
        let block = spec.blocks.remove(at: from)
        spec.blocks.insert(block, at: to)
        return spec
    }

    func editingBlock(_ index: Int, content: String) -> WhiteboardSpec {
        var spec = self
        guard blocks.indices.contains(index) else { return self }
        spec.blocks[index].content = content
        return spec
    }

    // MARK: 供 Agent 读板（whiteboard 工具 get 动作）与结果摘要

    /// 逐块清单文本（get 动作返回）：模型据此"读板→改图"迭代，
    /// 不必盲写。image 块不回传 data URI（万级字符的无信息量噪音），
    /// 只报尺寸。
    func readout(maxContentChars: Int = 1500) -> String {
        guard !blocks.isEmpty else { return "Whiteboard is empty." }
        var lines = ["Whiteboard \"\(title)\" — \(blocks.count) block(s)"]
        for (i, block) in blocks.enumerated() {
            var content = block.content
            if block.type == WhiteboardBlock.Kind.image,
               let comma = content.firstIndex(of: ",") {
                let payload = content.count - content.distance(from: content.startIndex, to: comma) - 1
                content = "data URI, ~\(max(0, payload / 4 * 3)) bytes"
            } else if content.count > maxContentChars {
                content = String(content.prefix(maxContentChars)) + "…[truncated \(content.count - maxContentChars) chars]"
            }
            lines.append("--- block \(i + 1) [\(block.type)]\(block.title.map { " \($0)" } ?? "") ---\n\(content)")
        }
        return lines.joined(separator: "\n")
    }

    /// 单行块摘要（render/append 的工具返回附带）：模型不调 get 也知道
    /// 板上有什么。
    func blockListSummary(limit: Int = 8) -> String {
        let parts = blocks.prefix(limit).enumerated().map { i, block in
            "\(i + 1).[\(block.type)]\(block.title ?? "")"
        }
        let more = blocks.count > limit ? " …(+\(blocks.count - limit))" : ""
        return parts.joined(separator: " ") + more
    }
}
