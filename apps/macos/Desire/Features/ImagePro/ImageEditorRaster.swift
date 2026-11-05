import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// ImagePro 像素引擎（v0.8.46 重写）：所有绘制/合成/选区/滤镜都在这里，
/// 输入输出一律 **base 像素坐标（左上原点、y 向下）**。纯函数，便于测试。
nonisolated enum ImageEditorRaster {

    // MARK: - 基础画布

    static func transparent(size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// 在副本上绘制（y 向下坐标系；内部自动翻转到 CGContext）。
    static func drawingContext(_ base: CGImage) -> CGContext? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    static func color(from color: NSColor) -> CGColor {
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor.red
        return CGColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                       blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    static func color(from hex: String) -> CGColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return CGColor(srgbRed: CGFloat((value >> 24) & 0xFF) / 255,
                       green: CGFloat((value >> 16) & 0xFF) / 255,
                       blue: CGFloat((value >> 8) & 0xFF) / 255,
                       alpha: CGFloat(value & 0xFF) / 255)
    }

    static func hexString(from cgColor: CGColor) -> String {
        let ns = NSColor(cgColor: cgColor) ?? .red
        let rgb = ns.usingColorSpace(.sRGB) ?? .red
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - 图层合成

    static func composite(layers: [ImageEditorLayer],
                          bitmaps: [UUID: CGImage],
                          size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for layer in layers where layer.isVisible && layer.opacity > 0.001 {
            guard let bitmap = bitmaps[layer.id] else { continue }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(layer.opacity))
            ctx.setBlendMode(layer.blend.cgBlendMode)
            // y-down 偏移 → CGContext(y-up) 的 -y；偏移取整避免重采样发虚。
            ctx.draw(bitmap, in: CGRect(x: layer.offset.width.rounded(),
                                        y: (-layer.offset.height).rounded(),
                                        width: CGFloat(w), height: CGFloat(h)))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func flattened(_ base: CGImage, over backdrop: CGColor?) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let backdrop {
            ctx.setFillColor(backdrop)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 画笔 / 橡皮

    /// 软边圆形画笔（沿折线等距落章）。`hardness` 0…1（1 = 硬边）。
    static func stroke(_ base: CGImage,
                       points: [CGPoint],
                       size: CGFloat,
                       color: CGColor,
                       opacity: CGFloat,
                       hardness: CGFloat,
                       erase: Bool,
                       clipMask: CGImage? = nil,
                       contentOffset: CGSize = .zero) -> CGImage? {
        guard let ctx = drawingContext(base) else { return nil }
        // 图层偏移：调用方传的是文档像素，落到位图上要减去偏移。
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        let radius = max(0.5, size / 2)
        let spacing = max(0.6, radius * 0.22)
        let stampPoints = Self.stampPoints(points, spacing: spacing)
        if erase { ctx.setBlendMode(.destinationOut) }
        let ns = NSColor(cgColor: color) ?? .black
        let rgb = ns.usingColorSpace(.sRGB) ?? .black
        let solid = CGColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                            blue: rgb.blueComponent, alpha: 1)
        let clear = CGColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                            blue: rgb.blueComponent, alpha: 0)
        let soft = min(1, max(0, hardness))
        for p in stampPoints {
            drawStamp(ctx, center: p, radius: radius,
                      inner: solid, outer: clear, hardness: soft,
                      alpha: opacity)
        }
        ctx.setBlendMode(.normal)
        guard let drawn = ctx.makeImage() else { return nil }
        // 选区约束（PS 行为）：只在选区内生效。用 CIBlendWithMask 混回，
        // 与"调节/滤镜"同一条已验证路径（CGContext.clip 的蒙版方向在
        // 翻转上下文里反复踩坑）。
        if let clipMask {
            return maskedBlend(base: base, effect: drawn, mask: clipMask) ?? drawn
        }
        return drawn
    }

    /// 用灰度蒙版把 effect 混回 base（白 = 用 effect）。
    /// 自己按像素混（空间和方向都不依赖框架约定）——CIBlendWithMask 在
    /// 灰度蒙版 + 翻转上下文这一组合上实测有位移/半区问题。
    static func maskedBlend(base: CGImage, effect: CGImage, mask: CGImage) -> CGImage? {
        let w = base.width, h = base.height
        guard w > 0, h > 0,
              effect.width == w, effect.height == h,
              mask.width == w, mask.height == h,
              let baseBytes = rgbaBytes(base),
              let effectBytes = rgbaBytes(effect),
              let maskBytes = grayBytes(mask) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Double(maskBytes[i]) / 255
            let inv = 1 - a
            let o = i * 4
            // 预乘 alpha 的线性插值 = 正确的交叉淡入淡出
            out[o] = UInt8((Double(baseBytes[o]) * inv + Double(effectBytes[o]) * a).rounded())
            out[o + 1] = UInt8((Double(baseBytes[o + 1]) * inv + Double(effectBytes[o + 1]) * a).rounded())
            out[o + 2] = UInt8((Double(baseBytes[o + 2]) * inv + Double(effectBytes[o + 2]) * a).rounded())
            out[o + 3] = UInt8((Double(baseBytes[o + 3]) * inv + Double(effectBytes[o + 3]) * a).rounded())
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self,
                                                               capacity: w * h * 4),
                                         count: w * h * 4))
    }

    private static func grayBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: w * h),
                                         count: w * h))
    }

    private static func stampPoints(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var out: [CGPoint] = [first]
        var last = first
        for p in points.dropFirst() {
            let dx = p.x - last.x, dy = p.y - last.y
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist > 0 else { continue }
            var t = spacing
            while t <= dist {
                out.append(CGPoint(x: last.x + dx * (t / dist),
                                   y: last.y + dy * (t / dist)))
                t += spacing
            }
            last = p
        }
        if points.count > 1, out.last != points.last { out.append(points[points.count - 1]) }
        return out
    }

    private static func drawStamp(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                                  inner: CGColor, outer: CGColor, hardness: CGFloat,
                                  alpha: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: [inner, inner, outer] as CFArray,
                                        locations: [0, hardness, 1]) else { return }
        ctx.saveGState()
        // 每章透明度通过图层 alpha 叠加；用 shadow 不行——直接乘到渐变颜色上
        ctx.setAlpha(alpha)
        ctx.drawRadialGradient(gradient,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [])
        ctx.restoreGState()
    }

    /// 平移整张位图（从原图重画，不累积裁切——move 来回拖动不会丢内容）。
    static func translated(_ image: CGImage, dx: CGFloat, dy: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: dx, y: -dy, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// 蒙版按图层偏移平移（文档空间蒙版 → 位图空间）。
    static func shiftedMask(_ mask: CGImage, dx: CGFloat, dy: CGFloat) -> CGImage? {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // 蒙版是 y-up device 空间：y-down 的 dy 对应 -dy
        ctx.draw(mask, in: CGRect(x: dx, y: -dy, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// 灰度蒙版 → alpha 蒙版（CGContext.clip(to:mask:) 需要 alpha 语义）。
    static func alphaMask(from gray: CGImage) -> CGImage? {
        let w = gray.width, h = gray.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.makeImage() else { return nil }
        guard let filter = CIFilter(name: "CIMaskToAlpha") else { return nil }
        filter.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
        guard let out = filter.outputImage,
              let alpha = ImagePipelineRenderer.context.createCGImage(out, from: out.extent)
        else { return nil }
        // clip(to:mask:) 会跟着当前 CTM 走，而绘制上下文是 y 翻转的
        //（y-down 图像坐标）——蒙版必须预翻转，否则选区镜像到另一半
        //（实测：选区 0..200 却裁到 150..305）。
        return flippedVertically(alpha) ?? alpha
    }

    /// 垂直翻转（用于把 device 空间的蒙版对齐到翻转后的绘制上下文）。
    static func flippedVertically(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 形状

    static func drawShape(_ base: CGImage, shape: ImageEditorShape,
                          from: CGPoint, to: CGPoint,
                          stroke: CGColor?, fill: CGColor?, lineWidth: CGFloat,
                          contentOffset: CGSize = .zero) -> CGImage? {
        guard let ctx = drawingContext(base) else { return nil }
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        ctx.setLineWidth(max(0.5, lineWidth))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch shape {
        case .rectangle, .ellipse:
            let path = CGPath(rect: rect, transform: nil)
            if shape == .ellipse {
                if let fill {
                    ctx.setFillColor(fill)
                    ctx.fillEllipse(in: rect)
                }
                if let stroke {
                    ctx.setStrokeColor(stroke)
                    ctx.strokeEllipse(in: rect)
                }
            } else {
                if let fill {
                    ctx.setFillColor(fill)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                if let stroke {
                    ctx.setStrokeColor(stroke)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
        case .line:
            if let stroke {
                ctx.setStrokeColor(stroke)
                ctx.move(to: from)
                ctx.addLine(to: to)
                ctx.strokePath()
            }
        case .arrow:
            if let stroke {
                ctx.setStrokeColor(stroke)
                ctx.move(to: from)
                ctx.addLine(to: to)
                ctx.strokePath()
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(10, lineWidth * 4)
                for offset in [CGFloat.pi * 0.75, -CGFloat.pi * 0.75] {
                    ctx.move(to: to)
                    ctx.addLine(to: CGPoint(x: to.x + head * cos(angle + offset),
                                            y: to.y + head * sin(angle + offset)))
                    ctx.strokePath()
                }
            }
        }
        return ctx.makeImage()
    }

    // MARK: - 文字

    static func drawText(_ base: CGImage, text: String, at anchor: CGPoint,
                         fontSize: CGFloat, color: CGColor,
                         fontName: String? = nil,
                         contentOffset: CGSize = .zero) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        guard let ctx = drawingContext(base) else { return nil }
        let nsColor = NSColor(cgColor: color) ?? .white
        let font = fontName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: nsColor,
        ]
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        NSGraphicsContext.saveGraphicsState()
        // drawingContext 已翻转成 y-down；NSGraphicsContext(flipped: true) 与之匹配。
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (trimmed as NSString).draw(at: anchor, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - 马赛克

    static func mosaic(_ base: CGImage, rect: CGRect, block: CGFloat,
                       contentOffset: CGSize = .zero) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0,
                                               width: base.width, height: base.height)).integral
        guard clamped.width >= 2, clamped.height >= 2 else { return base }
        let sourceRect = clamped.offsetBy(dx: -contentOffset.width, dy: -contentOffset.height)
        guard let region = ImageTransforms.cropped(base, rect: sourceRect) else { return base }
        let blockPx = max(2, block)
        let tinyW = max(1, Int(clamped.width / blockPx))
        let tinyH = max(1, Int(clamped.height / blockPx))
        guard let tiny = ImageTransforms.resized(region, width: tinyW, height: tinyH),
              let pixelated = ImageTransforms.resized(tiny, width: Int(clamped.width),
                                                      height: Int(clamped.height)),
              let ctx = drawingContext(base) else { return base }
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        // 像素化内容纵向对称，翻转不可见
        ctx.draw(pixelated, in: clamped)
        return ctx.makeImage()
    }

    // MARK: - 选区蒙版

    /// 生成灰度蒙版（白 = 选中）。`mask` 非空时直接用（魔棒/套索产出）。
    static func selectionMask(_ selection: ImageEditorSelection,
                              size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        var image: CGImage?
        if let mask = selection.mask {
            image = mask
        } else if let rect = selection.rect {
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(gray: 1, alpha: 1)
            // rect 是 y-down；CGContext 左下原点
            let flipped = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY,
                                 width: rect.width, height: rect.height)
            if selection.isEllipse {
                ctx.fillEllipse(in: flipped)
            } else {
                ctx.fill(flipped)
            }
            image = ctx.makeImage()
        } else if selection.selectAll {
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            image = ctx.makeImage()
        }
        guard var result = image else { return nil }
        if selection.feather > 0 {
            let radius = selection.feather * Double(min(w, h)) * 0.5
            if radius > 0.5,
               let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(CIImage(cgImage: result), forKey: kCIInputImageKey)
                blur.setValue(radius, forKey: kCIInputRadiusKey)
                if let out = blur.outputImage,
                   let cropped = ImagePipelineRenderer.context.createCGImage(
                       out, from: CGRect(x: 0, y: 0, width: w, height: h)) {
                    result = cropped
                }
            }
        }
        if selection.inverted {
            if let invert = CIFilter(name: "CIColorInvert") {
                invert.setValue(CIImage(cgImage: result), forKey: kCIInputImageKey)
                if let out = invert.outputImage,
                   let mixed = ImagePipelineRenderer.context.createCGImage(out, from: out.extent) {
                    result = mixed
                }
            }
        }
        return result
    }

    /// 画布坐标（base 像素）下的套索多边形蒙版。
    static func polygonMask(points: [CGPoint], size: CGSize, feather: Double) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        guard points.count >= 3,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.beginPath()
        let flipped = points.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) }
        ctx.move(to: flipped[0])
        for p in flipped.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()
        guard var image = ctx.makeImage() else { return nil }
        if feather > 0 {
            let radius = feather * Double(min(w, h)) * 0.5
            if radius > 0.5, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
                blur.setValue(radius, forKey: kCIInputRadiusKey)
                if let out = blur.outputImage,
                   let cropped = ImagePipelineRenderer.context.createCGImage(
                       out, from: CGRect(x: 0, y: 0, width: w, height: h)) {
                    image = cropped
                }
            }
        }
        return image
    }

    /// 选区布尔组合（像素级，白 = 选中）。
    enum SelectionCombine: String {
        case replace, add, subtract, intersect
    }

    static func combineMasks(_ base: CGImage?, _ other: CGImage,
                             mode: SelectionCombine) -> CGImage? {
        switch mode {
        case .replace:
            return other
        case .add, .subtract, .intersect:
            guard let base else {
                if mode == .add { return other }
                // 无选区时减/交 = 空
                return nil
            }
            guard base.width == other.width, base.height == other.height,
                  let a = grayBytes(base), let b = grayBytes(other) else { return base }
            let total = base.width * base.height
            var out = [UInt8](repeating: 0, count: total)
            for i in 0..<total {
                let x = Int(a[i]), y = Int(b[i])
                switch mode {
                case .add: out[i] = UInt8(max(x, y))
                case .subtract: out[i] = UInt8(max(0, x - y))
                case .intersect: out[i] = UInt8(min(x, y))
                case .replace: out[i] = UInt8(y)
                }
            }
            guard let provider = CGDataProvider(data: Data(out) as CFData),
                  let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
            return CGImage(width: base.width, height: base.height,
                           bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: base.width, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)
        }
    }

    /// 蒙版包围盒（文档坐标 y-down）。用与 maskedBlend 同一份像素视图，
    /// 避免两套方向约定（旧版自己建 context 扫描，实测 bbox 只有 1/3 高）。
    static func maskBounds(_ mask: CGImage) -> CGRect? {
        guard let bytes = grayBytes(mask) else { return nil }
        let w = mask.width, h = mask.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where bytes[row + x] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - 调节 / 滤镜（可选蒙版）

    static func applyEffect(_ base: CGImage,
                            adjust: ImageAdjustParams?,
                            filter: ImageFilterPreset?,
                            mask: CGImage?) -> CGImage? {
        var pipeline = ImageEditPipeline()
        if let adjust, !adjust.isNeutral {
            _ = pipeline.append(.adjust(adjust))
        }
        if let filter, filter != .none {
            _ = pipeline.append(.filter(filter.rawValue))
        }
        guard pipeline.operations.isEmpty == false else { return base }
        if let mask {
            return ImagePipelineRenderer.renderWithCustomMask(base: base, pipeline: pipeline,
                                                              mask: mask)
        }
        return ImagePipelineRenderer.render(base: base, pipeline: pipeline)
    }

    // MARK: - 采样

    static func sampleColor(_ image: CGImage, at point: CGPoint) -> CGColor? {
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (y * image.width + x) * 4
        return CGColor(srgbRed: CGFloat(buffer[offset]) / 255,
                       green: CGFloat(buffer[offset + 1]) / 255,
                       blue: CGFloat(buffer[offset + 2]) / 255,
                       alpha: CGFloat(buffer[offset + 3]) / 255)
    }
}

nonisolated extension ImageEditorBlend {
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .add: return .plusLighter
        }
    }
}
