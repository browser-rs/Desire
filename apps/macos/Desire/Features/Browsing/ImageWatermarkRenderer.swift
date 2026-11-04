import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 水印核心（v0.8.42 批 2）：文字/图片水印的位置/缩放/透明度/平铺参数。
/// 纯数据 + 校验；渲染在 `ImageWatermarkRenderer`（CoreGraphics）。
nonisolated struct ImageWatermarkParams: Codable, Equatable {
    enum Kind: String, Codable { case text, image }

    var kind: Kind
    var text: String = ""
    /// 图片水印的路径（workspace 或用户目录）
    var imagePath: String = ""
    /// 九宫格位置：0 = 左上，1 = 上中，2 = 右上，3 = 左中，4 = 居中，5 = 右中，6 = 左下，7 = 下中，8 = 右下
    var position: Int = 8
    /// 0…1
    var opacity: Double = 0.6
    /// 文字字号缩放（相对图片短边比例 0.02…0.15）
    var scale: Double = 0.04
    /// 旋转角度（-180…180）
    var rotation: Double = 0
    /// 平铺
    var tile: Bool = false
    /// 平铺间距比例 0.1…0.5
    var tileSpacing: Double = 0.25
    /// 文字颜色（hex RGB）
    var colorHex: String = "#FFFFFF"

    var isNeutral: Bool {
        (kind == .text && text.isEmpty) || (kind == .image && imagePath.isEmpty)
    }

    static func clamped(_ params: ImageWatermarkParams) -> ImageWatermarkParams {
        var p = params
        p.opacity = p.opacity.clamped(0.05, 1)
        p.scale = p.scale.clamped(0.02, 0.15)
        p.rotation = p.rotation.clamped(-180, 180)
        p.tileSpacing = p.tileSpacing.clamped(0.1, 0.5)
        p.position = max(0, min(8, p.position))
        return p
    }
}

nonisolated enum ImageWatermarkValidation {
    static func error(_ params: ImageWatermarkParams) -> String? {
        let p = ImageWatermarkParams.clamped(params)
        if p.kind == .text && p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter the watermark text.")
        }
        if p.kind == .image {
            guard !p.imagePath.isEmpty,
                  FileManager.default.fileExists(atPath: p.imagePath) else {
                return String(localized: "Watermark image not found.")
            }
        }
        return nil
    }
}

nonisolated enum ImageWatermarkRenderer {
    /// 把水印烙到 image 上，返回新图（值语义）。
    static func render(_ image: CGImage, params: ImageWatermarkParams) -> CGImage? {
        var p = params
        p.opacity = max(0.05, min(1, p.opacity))
        p.scale = max(0.02, min(0.15, p.scale))
        p.rotation = max(-180, min(180, p.rotation))
        p.tileSpacing = max(0.1, min(0.5, p.tileSpacing))
        p.position = max(0, min(8, p.position))
        guard !p.isNeutral else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(CGFloat(p.opacity))

        if p.tile {
            renderTiled(p, context: context, width: width, height: height)
        } else {
            renderSingle(p, context: context, width: width, height: height)
        }
        context.setAlpha(1)
        return context.makeImage()
    }

    private static func renderSingle(
        _ p: ImageWatermarkParams, context: CGContext, width: CGFloat, height: CGFloat
    ) {
        let scaled = min(width, height) * p.scale
        let margin = min(width, height) * 0.04
        let anchor = anchorPoint(p.position, width: width, height: height,
                                 margin: margin, contentSize: contentSize(p, scaled: scaled))
        context.saveGState()
        context.translateBy(x: anchor.x, y: anchor.y)
        if p.rotation != 0 {
            context.rotate(by: CGFloat(p.rotation) * .pi / 180)
        }
        drawContent(p, context: context, scaled: scaled, width: width, height: height)
        context.restoreGState()
    }

    private static func renderTiled(
        _ p: ImageWatermarkParams, context: CGContext, width: CGFloat, height: CGFloat
    ) {
        let scaled = min(width, height) * p.scale
        let spacing = min(width, height) * p.tileSpacing
        let contentSize = contentSize(p, scaled: scaled)
        let stepX = contentSize.x + spacing
        let stepY = contentSize.y + spacing
        let startX = -(contentSize.x.truncatingRemainder(dividingBy: stepX))
        let startY = -(contentSize.y.truncatingRemainder(dividingBy: stepY))
        var y = startY
        while y < height + contentSize.y {
            var x = startX
            while x < width + contentSize.x {
                context.saveGState()
                context.translateBy(x: x + contentSize.x / 2, y: y + contentSize.y / 2)
                if p.rotation != 0 {
                    context.rotate(by: CGFloat(p.rotation) * .pi / 180)
                }
                drawContent(p, context: context, scaled: scaled, width: width, height: height)
                context.restoreGState()
                x += stepX
            }
            y += stepY
        }
    }

    private static func contentSize(
        _ p: ImageWatermarkParams, scaled: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        switch p.kind {
        case .text:
            let fontSize = scaled
            let charW = fontSize * 0.55
            let w = max(CGFloat(p.text.count) * charW, 20)
            return (w, fontSize * 1.2)
        case .image:
            guard let image = loadImage(p.imagePath) else { return (20, 20) }
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            return (scaled * aspect, scaled)
        }
    }

    private static func anchorPoint(
        _ position: Int, width: CGFloat, height: CGFloat,
        margin: CGFloat, contentSize: (x: CGFloat, y: CGFloat)
    ) -> CGPoint {
        let col = position % 3
        let row = position / 3
        let anchorX: CGFloat
        let anchorY: CGFloat
        switch col {
        case 0: anchorX = margin
        case 1: anchorX = (width - contentSize.x) / 2
        default: anchorX = width - margin - contentSize.x
        }
        // CG 坐标 y 向上：row 0 = 顶部
        switch row {
        case 0: anchorY = height - margin - contentSize.y
        case 1: anchorY = (height - contentSize.y) / 2
        default: anchorY = margin
        }
        return CGPoint(x: anchorX, y: anchorY)
    }

    private static func drawContent(
        _ p: ImageWatermarkParams, context: CGContext,
        scaled: CGFloat, width: CGFloat, height: CGFloat
    ) {
        switch p.kind {
        case .text:
            context.setTextDrawingMode(.fill)
            let color = hexToColor(p.colorHex)
            context.setFillColor(color)
            let font = NSFont.systemFont(ofSize: scaled, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: NSColor(cgColor: color) ?? .white]
            let attributed = NSAttributedString(string: p.text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            context.textPosition = CGPoint(x: 0, y: -bounds.height / 2)
            CTLineDraw(line, context)
        case .image:
            guard let image = loadImage(p.imagePath) else { return }
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let drawW = scaled * aspect
            let drawH = scaled
            context.draw(image, in: CGRect(x: -drawW / 2, y: -drawH / 2,
                                           width: drawW, height: drawH))
        }
    }

    private static func loadImage(_ path: String) -> CGImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)?.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
    }

    private static func hexToColor(_ hex: String) -> CGColor {
        var clean = hex.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return CGColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
