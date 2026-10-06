import Foundation

// MARK: - 触盘能力目录（v4：八选四）

/// 触盘 2×2 槽位可放的能力（v4 可定制）。默认四枚 = V3 定稿布局。
enum BallCapability: String, CaseIterable, Identifiable {
    case conversation   // Agent 对话（V3）
    case voice          // 语音输入（V3）
    case summarize      // 总结本页（V3）
    case whiteboard     // 白板（V3）
    case screenshot     // 系统截图
    case translate      // 翻译本页
    case plan           // 任务计划（面板内计划卡）
    case customPrompt   // 自定义提示词（设置页可编辑文本）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conversation: "Agent 对话"
        case .voice: "语音输入"
        case .summarize: "总结本页"
        case .whiteboard: "白板"
        case .screenshot: "截图"
        case .translate: "翻译本页"
        case .plan: "任务计划"
        case .customPrompt: "自定义提示词"
        }
    }

    var icon: String {
        switch self {
        case .conversation: "bubble.left.and.text.bubble.right"
        case .voice: "mic.fill"
        case .summarize: "doc.text.magnifyingglass"
        case .whiteboard: "rectangle.dashed"
        case .screenshot: "camera.viewfinder"
        case .translate: "character.book.closed"
        case .plan: "checklist"
        case .customPrompt: "wand.and.stars"
        }
    }

    /// V3 定稿布局（nonisolated：持久化解码在非隔离上下文也要能引用）。
    nonisolated static let defaultSlots: [BallCapability] = [.conversation, .voice, .summarize, .whiteboard]

    /// 持久化解码：非法/缺位回退默认（数量 != 4 或含未知值即视为坏档）。
    nonisolated static func decodeSlots(_ raw: [String]) -> [BallCapability] {
        let decoded = raw.compactMap { BallCapability(rawValue: $0) }
        var seen = Set<BallCapability>()
        let unique = decoded.filter { seen.insert($0).inserted }
        guard unique.count == 4 else { return defaultSlots }
        return unique
    }
}
