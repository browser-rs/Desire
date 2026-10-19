import AppKit
import CoreGraphics

/// 白板 PDF 导出（v0.7.24）：整板离屏渲染成图 → 按 A4 逐页纵向切分
///（布局数学在 `WhiteboardPDFLayout`，可单测）。不画分享卡头部——PDF 是
/// "打印/归档"形态，板名走 PDF 元数据（kCGPDFContextTitle）。
enum WhiteboardPDFExport {
    /// 返回 (PDF 数据, 页数)。空板/渲染失败抛错（调用方给用户可见文案）。
    static func pdfData(board: WhiteboardSpec) async throws -> (data: Data, pages: Int) {
        let contentWidth = CGFloat(WhiteboardPDFLayout.contentWidth)
        var forRender = board
        forRender.title = ""   // 标题走元数据，不在画布重复
        let rendered = try await BoardRenderService.shared.render(forRender, width: contentWidth)
        let image = rendered.image
        guard image.size.height > 1,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "WhiteboardPDF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "白板渲染成图失败"])
        }
        let slices = WhiteboardPDFLayout.slices(scaledHeight: Double(image.size.height))
        guard !slices.isEmpty else {
            throw NSError(domain: "WhiteboardPDF", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "白板是空的"])
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw NSError(domain: "WhiteboardPDF", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PDF 容器创建失败"])
        }
        var mediaBox = CGRect(x: 0, y: 0,
                              width: WhiteboardPDFLayout.pageWidth,
                              height: WhiteboardPDFLayout.pageHeight)
        let info: [String: Any] = [kCGPDFContextTitle as String: board.title]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw NSError(domain: "WhiteboardPDF", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PDF 上下文创建失败"])
        }
        let margin = CGFloat(WhiteboardPDFLayout.margin)
        let contentHeight = CGFloat(WhiteboardPDFLayout.contentHeight)
        let contentRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
        for slice in slices {
            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: contentRect)
            // CG 原点在左下：图顶对齐"内容区顶 + 已切掉的 top"，随 top 上移。
            let imageBottom = contentRect.maxY + CGFloat(slice.top) - image.size.height
            context.draw(cgImage, in: CGRect(x: margin, y: imageBottom,
                                             width: contentWidth, height: image.size.height))
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return (data as Data, slices.count)
    }
}
