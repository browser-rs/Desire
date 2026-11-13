import CoreGraphics
import Foundation

/// lookImage compare 拼图与缩放（v0.8.55 批 1）：before/after **同高并排**
/// + 中央分隔线。布局计算与绘制全部 Foundation/CoreGraphics（无 AppKit），
/// 进 tests/run.sh——修图闭环"自检"一步的确定性底座。
nonisolated enum ImageLookCompare {

    /// 并排布局：两张图缩放到同一高度（各保持宽高比），水平排列，中间
    /// `divider` 宽的分隔带。目标高 = 两图较小高与 `maxHeight` 取小。
    struct Layout: Equatable {
        let canvasSize: CGSize
        let beforeRect: CGRect
        let afterRect: CGRect
        let dividerRect: CGRect
    }

    static func layout(beforeSize: CGSize, afterSize: CGSize,
                       divider: CGFloat = 4, maxHeight: CGFloat = 1024) -> Layout {
        let bh = max(1, beforeSize.height)
        let ah = max(1, afterSize.height)
        let height = max(1, min(maxHeight, min(bh, ah)))
        let beforeWidth = max(1, beforeSize.width / bh * height)
        let afterWidth = max(1, afterSize.width / ah * height)
        let totalWidth = beforeWidth + divider + afterWidth
        return Layout(
            canvasSize: CGSize(width: totalWidth, height: height),
            beforeRect: CGRect(x: 0, y: 0, width: beforeWidth, height: height),
            afterRect: CGRect(x: beforeWidth + divider, y: 0,
                              width: afterWidth, height: height),
            dividerRect: CGRect(x: beforeWidth, y: 0, width: divider, height: height))
    }

    /// 渲染并排图（浅灰底 + 分隔带）。任一步失败返回 nil（调用方转 error）。
    static func compose(before: CGImage, after: CGImage,
                        divider: CGFloat = 4) -> CGImage? {
        let layout = layout(beforeSize: CGSize(width: before.width, height: before.height),
                            afterSize: CGSize(width: after.width, height: after.height),
                            divider: divider)
        let width = Int(layout.canvasSize.width.rounded())
        let height = Int(layout.canvasSize.height.rounded())
        let canvasHeight = layout.canvasSize.height
        // CG 坐标系 y 向上：绘制矩形翻转 y，让"图像顶边对齐"与文档像素一致。
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: canvasHeight - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(before, in: flipped(layout.beforeRect))
        context.draw(after, in: flipped(layout.afterRect))
        context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.6, alpha: 1))
        context.fill(flipped(layout.dividerRect))
        return context.makeImage()
    }

    /// 长边 ≤ `maxSide` 的等比缩小（vision 通道省 token；纯 CG 双线性）。
    /// 已小于上限时原样返回。
    static func downscaled(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > maxSide, maxSide >= 1 else { return image }
        let scale = maxSide / longEdge
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
