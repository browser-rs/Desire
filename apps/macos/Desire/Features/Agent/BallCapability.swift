import Foundation

// MARK: - 触盘能力目录（v7：十四项，特色快捷操作入盘）

/// 触盘 2×2 槽位可放的能力（可定制；长按球展开全部）。默认四枚 = V3 定稿布局。
enum BallCapability: String, CaseIterable, Identifiable {
    case conversation   // Agent 对话（V3）
    case voice          // 语音输入（V3）
    case summarize      // 总结本页（V3）
    case whiteboard     // 白板（V3）
    case screenshot     // 系统截图
    case translate      // 翻译本页
    case plan           // 任务计划（面板内计划卡）
    case customPrompt   // 自定义提示词（设置页可编辑文本）
    // v7 特色快捷操作（用户点名：AI 去广告 / 下载页面视频 / 下载全部视频；
    // 高频快捷操作随后补——阅读模式、页内查找、收藏本页）。
    case adClean            // AI 去广告：手动扫描当前页并拦截高置信度广告
    case downloadPageVideo  // 下载页面视频：嗅探到的主视频（正在看的那个）
    case downloadAllVideos  // 下载全部视频：页面媒体全部入队（批量引擎）
    case readerMode         // 阅读模式切换
    case findInPage         // 页内查找
    case bookmarkPage       // 收藏本页

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
        case .adClean: "AI 去广告"
        case .downloadPageVideo: "下载页面视频"
        case .downloadAllVideos: "下载全部视频"
        case .readerMode: "阅读模式"
        case .findInPage: "页内查找"
        case .bookmarkPage: "收藏本页"
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
        case .adClean: "sparkles.rectangle.stack"
        case .downloadPageVideo: "arrow.down.circle"
        case .downloadAllVideos: "arrow.down.to.line.compact"
        case .readerMode: "text.page"
        case .findInPage: "text.magnifyingglass"
        case .bookmarkPage: "bookmark"
        }
    }

    /// V3 定稿布局（nonisolated：持久化解码在非隔离上下文也要能引用）。
    nonisolated static let defaultSlots: [BallCapability] = [.conversation, .voice, .summarize, .whiteboard]

    /// 默认全能力顺序：V3 四枚在前，其余按目录顺序随后。
    nonisolated static var defaultOrder: [BallCapability] {
        defaultSlots + allCases.filter { !defaultSlots.contains($0) }
    }

    /// 持久化解码：v4 档只存主盘 4 值——按 allCases 顺序**补齐全表**（v7
    /// 顺序表模型，前 4 语义不变）；非法值丢弃、重复去重，缺失项补尾。
    nonisolated static func decodeSlots(_ raw: [String]) -> [BallCapability] {
        let decoded = raw.compactMap { BallCapability(rawValue: $0) }
        var seen = Set<BallCapability>()
        let unique = decoded.filter { seen.insert($0).inserted }
        let rest = allCases.filter { !seen.contains($0) }
        return unique + rest
    }
}
