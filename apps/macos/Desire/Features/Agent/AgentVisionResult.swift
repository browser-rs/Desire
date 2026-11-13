import Foundation

/// 工具图片结果的 vision 文本标签（v0.8.55 批 1）。
///
/// 口径（与 AnthropicProvider 对齐）：**任何**以 `data:image/` 开头的工具结果
/// 都按 vision part 编码——Anthropic 路径一直如此（按前缀全收）；OpenAI 兼容
/// 路径此前硬编码只认 screenshot/screenshotElement，导致 pdfPageScreenshot、
/// whiteboard 自检截图、editImage 的 lookImage 在 OpenAI 端点上模型根本看不到图。
/// 标签随工具语义（工具结果里的 text part），未知工具给通用标签。
nonisolated enum AgentVisionResult {
    static func label(tool: String?) -> String {
        switch tool {
        case "screenshot": return "Screenshot of the current viewport"
        case "screenshotElement": return "Screenshot of one page element"
        case "pdfPageScreenshot": return "Rendered page image from a PDF file"
        case "whiteboard": return "Screenshot of the whiteboard"
        case "editImage": return "Image editor canvas (lookImage)"
        default: return "Image returned by \(tool ?? "tool")"
        }
    }
}
