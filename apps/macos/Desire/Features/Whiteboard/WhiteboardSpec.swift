import Foundation

/// 白板数据模型（§一期）：一块白板 = 有序的块列表。智能体与页面
/// 都只产出**结构化描述**（Mermaid 源码 / ECharts 配置 / Markdown），
/// 渲染交给本地双引擎——这是"白板 = 结构化数据的渲染器"的落点。
struct WhiteboardSpec: Codable, Equatable {
    var title: String
    var blocks: [WhiteboardBlock]

    /// .board 文件 schema 版本（0.7.1 社区分享）：导出写入，导入校验。
    /// 当前唯一版本 = "desire-board/1"；旧文件缺键按 /1 读（可选解码）；
    /// 更高版本结构未知，导入侧明确拒绝——静默解码会丢字段，宁拒不丢。
    static let boardSchemaVersion = "desire-board/1"

    var schemaVersion: String? = nil

    /// 一块板的块数上限（工具层护栏）：renderBoard 逐块渲染，块数失控
    /// 会把双引擎渲染与 DiskStore 落盘一起拖垮。面板编辑不受此限。
    static let maxBlocks = 60

    init(title: String = "白板", blocks: [WhiteboardBlock] = [], schemaVersion: String? = nil) {
        self.title = title
        self.blocks = blocks
        self.schemaVersion = schemaVersion
    }

    /// 导出用：带当前 schema 版本的副本。
    var shareable: WhiteboardSpec {
        var copy = self
        copy.schemaVersion = Self.boardSchemaVersion
        return copy
    }

    /// 导入信任摘要（0.7.1）：标题 + 块数 + 按类型的数量明细 + 数据安全性声明。
    /// .board 是纯数据（Mermaid 源码 / 图表配置 / Markdown / 图片 URI），
    /// 不含脚本或宏——这句话写进对话框，是导入信任的落点。
    var importSummary: String {
        let counts = Dictionary(grouping: blocks, by: \.type)
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()
            .joined(separator: "、")
        return "「\(title)」— \(blocks.count) 块（\(counts)）。\n"
            + ".board 是纯数据文件（图表源码 / Markdown / 图片），不含脚本或宏；渲染由本地引擎完成。"
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
    /// chart 块的自定义高度（px，钳制 120-800）；其余类型忽略。
    /// 旧文件缺键 → nil（可选解码，向后兼容）。
    var height: Double?

    enum Kind {
        static let mermaid = "mermaid"
        static let chart = "chart"
        static let note = "note"
        static let table = "table"
        static let image = "image"
        // v8 React 前端新增：flow = 节点图 JSON（React Flow + dagre 自动
        // 布局）；mindmap = 缩进层级文本（markmap 渲染，XMind 观感）。
        static let flow = "flow"
        static let mindmap = "mindmap"
    }

    /// image 块的内容上限（data URI 字符数 ≈ 8MB 二进制）——防止一次截图
    /// 把 DiskStore 落盘与 .board JSON 撑爆。
    static let maxImageContentChars = 11_000_000

    init(id: UUID = UUID(), type: String, title: String? = nil, content: String, height: Double? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.height = height
    }

    /// chart 块渲染高度（px）：显式 height 钳制 120-800，缺省 320。
    var chartHeight: Double {
        guard let height, height.isFinite else { return 320 }
        return min(max(height, 120), 800)
    }

    var isValid: Bool {
        guard [WhiteboardBlock.Kind.mermaid, WhiteboardBlock.Kind.chart,
               WhiteboardBlock.Kind.note, WhiteboardBlock.Kind.table,
               WhiteboardBlock.Kind.image, WhiteboardBlock.Kind.flow,
               WhiteboardBlock.Kind.mindmap].contains(type) else { return false }
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
        let height = (item["height"] as? Double)
            ?? (item["height"] as? Int).map(Double.init)
            ?? (item["height"] as? String).flatMap(Double.init)
        let block = WhiteboardBlock(type: type, title: item["title"] as? String, content: content, height: height)
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

    /// 按位置插入（index 为 0-based"插到此块之前"；nil = 追加到末尾）。
    /// 越界原样返回（工具层负责换算 1-based 与报错）。
    func insertingBlocks(_ newBlocks: [WhiteboardBlock], at index: Int?) -> WhiteboardSpec {
        var spec = self
        let at = index ?? spec.blocks.count
        guard at >= 0, at <= spec.blocks.count, !newBlocks.isEmpty else { return self }
        spec.blocks.insert(contentsOf: newBlocks, at: at)
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

    /// Markdown 导出（面板/桥共用）：mermaid/chart 围栏化、note/table 原文、
    /// image 内联 data URI（保真优先）。可贴进任何 Markdown 工具。
    func markdownExport() -> String {
        guard !blocks.isEmpty else { return "# \(title)\n\n（白板是空的）\n" }
        var out = ["# \(title)", ""]
        for (i, block) in blocks.enumerated() {
            let caption = block.title.map { " \($0)" } ?? ""
            out.append("## \(i + 1). [\(block.type)]\(caption)")
            out.append("")
            switch block.type {
            case WhiteboardBlock.Kind.mermaid:
                out.append("```mermaid")
                out.append(block.content)
                out.append("```")
            case WhiteboardBlock.Kind.chart:
                out.append("```json")
                out.append(block.content)
                out.append("```")
            case WhiteboardBlock.Kind.image:
                out.append("![\(block.title ?? "image")](\(block.content))")
            default:
                out.append(block.content)
            }
            out.append("")
        }
        return out.joined(separator: "\n")
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
