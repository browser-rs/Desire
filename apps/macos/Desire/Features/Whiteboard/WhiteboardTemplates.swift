import Foundation

/// 白板模板库（0.6.9）：预置块组合，面板「+」菜单一键成板。
/// 模板即普通块数组（Foundation-only，进 tests/run.sh）；**分享复用既有
/// .board 导入/导出**——把模板当一块板导出即可，不另设格式。
struct WhiteboardTemplate: Identifiable {
    var id: String
    var name: String
    var icon: String      // SF Symbol（面板菜单用）
    var blocks: [WhiteboardBlock]
}

enum WhiteboardTemplates {
    static let builtIn: [WhiteboardTemplate] = [
        WhiteboardTemplate(
            id: "competitor", name: "竞品对比", icon: "scalemass",
            blocks: [
                WhiteboardBlock(type: WhiteboardBlock.Kind.note, title: nil,
                                content: "## 竞品对比\n先填结论，表格只放支撑事实。"),
                WhiteboardBlock(type: WhiteboardBlock.Kind.table, title: "对比矩阵",
                                content: """
                                | 维度 | 产品 A | 产品 B | 我们 |
                                | --- | --- | --- | --- |
                                | 价格 | | | |
                                | 核心功能 | | | |
                                | 生态/集成 | | | |
                                | 服务与支持 | | | |
                                """),
            ]),
        WhiteboardTemplate(
            id: "weekly", name: "周报", icon: "calendar",
            blocks: [
                WhiteboardBlock(type: WhiteboardBlock.Kind.note, title: nil, content: """
                ## 本周完成
                -
                ## 下周计划
                -
                ## 风险与求助
                -
                """),
            ]),
        WhiteboardTemplate(
            id: "retro", name: "流程复盘", icon: "arrow.triangle.branch",
            blocks: [
                WhiteboardBlock(type: WhiteboardBlock.Kind.mermaid, title: "事件链",
                                content: "graph LR\n    A[触发] --> B[处理]\n    B --> C{卡点?}\n    C -->|是| D[复盘]\n    C -->|否| E[交付]"),
                WhiteboardBlock(type: WhiteboardBlock.Kind.note, title: nil, content: """
                ## 复盘
                - 哪里卡住了：
                - 根因：
                - 下次怎么做：
                """),
            ]),
        WhiteboardTemplate(
            id: "meeting", name: "会议纪要", icon: "person.3",
            blocks: [
                WhiteboardBlock(type: WhiteboardBlock.Kind.note, title: nil, content: """
                ## 会议纪要
                - 时间/与会人：
                - 结论：
                """),
                WhiteboardBlock(type: WhiteboardBlock.Kind.table, title: "行动项",
                                content: """
                                | 事项 | 负责人 | 截止 |
                                | --- | --- | --- |
                                |  |  |  |
                                """),
            ]),
        WhiteboardTemplate(
            id: "swot", name: "SWOT", icon: "square.grid.2x2",
            blocks: [
                WhiteboardBlock(type: WhiteboardBlock.Kind.table, title: "SWOT",
                                content: """
                                | **S 优势** | **W 劣势** |
                                | --- | --- |
                                |  |  |

                                | **O 机会** | **T 威胁** |
                                | --- | --- |
                                |  |  |
                                """),
            ]),
    ]
}
