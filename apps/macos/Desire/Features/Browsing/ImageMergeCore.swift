import CoreGraphics
import CoreImage
import Foundation

/// 拼图合成核心（迭代 2 · v0.8.43）：水平/垂直拼接两张或更多图片。
nonisolated enum ImageMergeCore {

    enum Direction: String, Codable, CaseIterable {
        case horizontal, vertical
    }

    struct MergeResult {
        let image: CGImage
        /// 输出尺寸（宽×高）
        let size: CGSize
    }

    /// 拼接 images（按顺序），gap 像素（白色填充）。
    /// 水平 = 左→右，高度对齐到最大（短图垂直居中）。
    /// 垂直 = 上→下，宽度对齐到最大（窄图水平居中）。
    static func merge(_ images: [CGImage], direction: Direction,
                      gap: CGFloat) -> MergeResult? {
        guard images.count >= 2 else { return nil }
        let safeGap = max(0, gap)
        let maxSize = CGSize(width: images.map(\.width).max() ?? 1,
                             height: images.map(\.height).max() ?? 1)

        let totalWidth: CGFloat
        let totalHeight: CGFloat
        switch direction {
        case .horizontal:
            totalWidth = images.reduce(0) { $0 + CGFloat($1.width) } + safeGap * CGFloat(images.count - 1)
            totalHeight = maxSize.height
        case .vertical:
            totalWidth = maxSize.width
            totalHeight = images.reduce(0) { $0 + CGFloat($1.height) } + safeGap * CGFloat(images.count - 1)
        }
        let totalW = Int(totalWidth.rounded())
        let totalH = Int(totalHeight.rounded())
        guard totalW > 0, totalH > 0,
              let context = CGContext(
                  data: nil, width: totalW, height: totalH,
                  bitsPerComponent: 8, bytesPerRow: totalW * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 白色背景（gap 填充）
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

        var cursor: CGFloat = 0
        for image in images {
            switch direction {
            case .horizontal:
                let offsetY = (CGFloat(totalH) - CGFloat(image.height)) / 2
                let drawRect = CGRect(x: cursor, y: offsetY,
                                      width: CGFloat(image.width),
                                      height: CGFloat(image.height))
                context.draw(image, in: drawRect)
                cursor += CGFloat(image.width) + safeGap
            case .vertical:
                let offsetX = (CGFloat(totalW) - CGFloat(image.width)) / 2
                cursor += CGFloat(image.height)
                let drawRect = CGRect(x: offsetX, y: CGFloat(totalH) - cursor,
                                      width: CGFloat(image.width),
                                      height: CGFloat(image.height))
                context.draw(image, in: drawRect)
                cursor += safeGap
            }
        }
        guard let result = context.makeImage() else { return nil }
        return MergeResult(image: result,
                           size: CGSize(width: totalW, height: totalH))
    }
}
