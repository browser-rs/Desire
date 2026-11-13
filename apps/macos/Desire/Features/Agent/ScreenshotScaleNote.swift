import CoreGraphics
import Foundation

/// 截图坐标自描述（v0.8.56 批 1）：`captureScreenshot` 在视口长边 >1024 时
/// 等比缩小，模型读截图报坐标不知道缩放系数（全屏 1512px 宽时漂 ~1.4x）——
/// clickAt 的视觉兜底回路在宽窗口下不可信。本类型算出目标尺寸与换算系数、
/// 生成烧进截图底部的 caption 行（模型读图即知换算）。
/// Foundation/CoreGraphics、进 tests/run.sh。
nonisolated enum ScreenshotScaleNote {

    /// caption 条的高度（px；烧在缩放后的截图下方）。
    static let captionHeight = 16

    struct Note: Equatable {
        /// 缩放后内容区的目标尺寸（caption 条之外）。
        let targetWidth: Int
        let targetHeight: Int
        /// 图片像素 → viewport CSS px 的换算系数（**乘**回去）。
        let scale: Double
        /// 烧进截图底部的 caption 行（英文、无空格包裹——模型直接读）。
        let caption: String
        /// 图片像素与 CSS px 一比一（视口长边 ≤ maxDimension）。
        let isExact: Bool
    }

    /// `viewportWidth/Height` 取截图点尺寸（= 视口 CSS px；retina 位图由
    /// NSImage.size 归一到点）。长边 ≤ maxDimension 时 1:1 不缩放。
    static func note(viewportWidth: Double, viewportHeight: Double,
                     maxDimension: Double = 1024) -> Note {
        let vw = max(1, viewportWidth)
        let vh = max(1, viewportHeight)
        let factor = min(1, maxDimension / max(vw, vh))
        let targetW = max(1, Int((vw * factor).rounded()))
        let targetH = max(1, Int((vh * factor).rounded()))
        let isExact = abs(factor - 1) < 0.0001
        let scaleText = isExact ? "1:1" : String(format: "%.3f", factor)
        let caption = "viewport \(Int(vw))x\(Int(vh)) | image \(targetW)x\(targetH) | "
            + "scale \(scaleText) | clickAt: viewport px = image px / scale"
        return Note(targetWidth: targetW, targetHeight: targetH,
                    scale: factor, caption: caption, isExact: isExact)
    }
}
