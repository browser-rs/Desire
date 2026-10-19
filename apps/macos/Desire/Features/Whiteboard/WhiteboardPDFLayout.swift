import Foundation

/// 白板 PDF 导出的**分页布局**（v0.7.24）：纯数学（Foundation-only，进 harness）。
/// 单位 = PDF 点（A4 = 595.28 × 841.89）；正文区四周留 36pt 边距。
/// 源图按正文宽渲染（缩放 = 1），只做**纵向切片**——横向不切（白板内容
/// 本就按页宽渲染，切横会切断图表）。
enum WhiteboardPDFLayout {
    static let pageWidth = 595.28
    static let pageHeight = 841.89
    static let margin = 36.0
    static let contentWidth = pageWidth - margin * 2
    static let contentHeight = pageHeight - margin * 2

    /// 每页的源图切片：`top` = 距图顶的距离（与 `height` 同单位，= 渲染后高度）。
    /// 空内容返回 []；恰满一页不多出空白页（`scaledHeight == contentHeight` → 1 页）。
    static func slices(scaledHeight: Double) -> [(top: Double, height: Double)] {
        guard scaledHeight > 0, scaledHeight.isFinite else { return [] }
        var out: [(top: Double, height: Double)] = []
        var top = 0.0
        while top < scaledHeight {
            out.append((top, min(contentHeight, scaledHeight - top)))
            top += contentHeight
        }
        return out
    }

    static func pageCount(scaledHeight: Double) -> Int {
        slices(scaledHeight: scaledHeight).count
    }
}
