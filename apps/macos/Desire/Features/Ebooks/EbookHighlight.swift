import Foundation

/// 高亮颜色（v0.8.35）：正文用半透明底色，备注/侧栏用不透明色点。
/// Foundation-only（进 tests/run.sh），SwiftUI 颜色由视图层从 rgb 构造。
nonisolated enum EbookHighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .pink: return String(localized: "Pink")
        }
    }

    /// 0...1 RGB（侧栏色点）。
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow: return (1.00, 0.84, 0.29)
        case .green: return (0.49, 0.83, 0.48)
        case .blue: return (0.43, 0.76, 1.00)
        case .pink: return (1.00, 0.56, 0.69)
        }
    }

    /// 正文底色（半透明，深色主题下仍能看清文字）。
    var backgroundCSS: String {
        let c = rgb
        func channel(_ value: Double) -> String {
            String(Int((value * 255).rounded()))
        }
        return "rgba(\(channel(c.red)),\(channel(c.green)),\(channel(c.blue)),0.38)"
    }
}

/// 书内高亮/笔记（v0.8.35）。锚点 = 章节内文本偏移（书内容固定，分页重建
/// 不改变文本顺序）；quote 只作显示与偏移失效时的兜底。
nonisolated struct EbookHighlight: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var chapterIndex: Int
    var chapterTitle: String
    /// 创建时的章内进度（0...1），用于跳转兜底。
    var chapterProgress: Double
    var quote: String
    /// JS 文本节点偏移（UTF-16）；-1 = 无偏移，只能按 quote 兜底。
    var startOffset: Int
    var endOffset: Int
    var color: EbookHighlightColor
    var note: String?
    var createdAt: Date

    init(id: UUID = UUID(), chapterIndex: Int, chapterTitle: String,
         chapterProgress: Double, quote: String, startOffset: Int, endOffset: Int,
         color: EbookHighlightColor = .yellow, note: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.chapterProgress = chapterProgress
        self.quote = quote
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }

    var hasOffsets: Bool { startOffset >= 0 && endOffset > startOffset }

    var trimmedNote: String? {
        let value = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
