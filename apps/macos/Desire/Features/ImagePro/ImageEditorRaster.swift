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

    /// 显示路径的图层位图预缩缓存：key = 位图身份 + 目标边长。位图被编辑
    /// 会产生新的 CGImage（CF身份不同），缓存天然失效，无需 revision。
    private static var prescaleCache: [UUID: (source: CGImage, maxSide: CGFloat,
                                              image: CGImage)] = [:]
    private static let prescaleLock = NSLock()

    /// 非破坏参数（adjust/filter）的渲染缓存：key = 图层 id + 位图身份 + 参数。
    /// 参数化位图挂在图层上合成时现算——缓存让"参数不变的连续编辑"不重跑
    /// CI 效果（96MP 上一次 applyEffect ~200ms+）。
    private static var effectCache: [UUID: (source: CGImage, adjust: ImageAdjustParams?,
                                            filter: ImageFilterPreset?, image: CGImage)] = [:]
    private static let effectLock = NSLock()

    /// 参数化位图（带缓存）。Document 烘焙活动层参数时复用同一份渲染。
    static func effectApplied(_ bitmap: CGImage, id: UUID,
                                      adjust: ImageAdjustParams?,
                                      filter: ImageFilterPreset?) -> CGImage {
        let neutral = (adjust == nil || adjust!.isNeutral)
            && (filter == nil || filter == ImageFilterPreset.none)
        if neutral { return bitmap }
        effectLock.lock()
        if let hit = effectCache[id], hit.source === bitmap,
           hit.adjust == adjust, hit.filter == filter {
            effectLock.unlock()
            return hit.image
        }
        effectLock.unlock()
        let rendered = applyEffect(bitmap, adjust: adjust, filter: filter, mask: nil)
            ?? bitmap
        effectLock.lock()
        effectCache[id] = (bitmap, adjust, filter, rendered)
        effectLock.unlock()
        return rendered
    }

    /// 合成。`maxRenderSide` 非空 = 显示路径：画布先缩到该边长内，各层位图
    /// 也按同一比例预缩（结果按图层 id 缓存）——超大图每笔编辑从
    /// "全分辨率合成+降采样"（6000×4000 实测 ~660ms）降到"小画布合成"
    /// （~90ms）。编辑/导出仍走全分辨率（maxRenderSide 缺省 nil）。
    static func composite(layers: [ImageEditorLayer],
                          bitmaps: [UUID: CGImage],
                          size: CGSize,
                          matching: ((ImageEditorLayer) -> Bool)? = nil,
                          maxRenderSide: CGFloat? = nil) -> CGImage? {
        // 显示比例：画布最长边钳到 maxRenderSide（仅显示路径）。
        let renderScale: CGFloat
        if let maxRenderSide {
            let side = max(size.width, size.height)
            renderScale = side > maxRenderSide ? maxRenderSide / side : 1
        } else {
            renderScale = 1
        }
        let w = max(1, Int((size.width * renderScale).rounded()))
        let h = max(1, Int((size.height * renderScale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for layer in layers where layer.isVisible && layer.opacity > 0.001
            && (matching?(layer) ?? true) {
            guard let rawBitmap = bitmaps[layer.id] else { continue }
            var bitmap = rawBitmap
            if renderScale < 1 {
                bitmap = prescaled(bitmap, id: layer.id, maxSide: maxRenderSide!)
            }
            // 非破坏参数（预缩后应用：显示路径小尺寸 CI 更便宜，视觉等价）。
            // 显示路径的 maxRenderSide 伴随更小的位图，effectCache 按位图身份
            // 分键，全分辨率与显示路径互不踩。
            if layer.adjust != nil || layer.filter != nil {
                bitmap = effectApplied(bitmap, id: layer.id,
                                       adjust: layer.adjust, filter: layer.filter)
            }
            if layer.style?.isActive == true {
                bitmap = styled(bitmap, style: layer.style!) ?? bitmap
            }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(layer.opacity))
            ctx.setBlendMode(layer.blend.cgBlendMode)
            let bw = CGFloat(bitmap.width), bh = CGFloat(bitmap.height)
            let offset = CGSize(width: (layer.offset.width * renderScale).rounded(),
                                height: (layer.offset.height * renderScale).rounded())
            let center = CGPoint(x: offset.width + bw / 2,
                                 y: CGFloat(h) - offset.height - bh / 2)
            ctx.translateBy(x: center.x, y: center.y)
            if layer.rotation != 0 {
                // 文档顺时针 → CG 的 y-up 逆时针
                ctx.rotate(by: CGFloat(-layer.rotation * .pi / 180))
            }
            if layer.scale != 1 {
                ctx.scaleBy(x: CGFloat(layer.scale), y: CGFloat(layer.scale))
            }
            ctx.draw(bitmap, in: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// 图层位图预缩（显示路径专用）：最长边钳到 maxSide。结果按图层 id 缓存
    /// （锁保护——displayComposite 与缩放/平移事件可能在不同线程碰它）。
    private static func prescaled(_ image: CGImage, id: UUID, maxSide: CGFloat) -> CGImage {
        prescaleLock.lock()
        defer { prescaleLock.unlock() }
        if let hit = prescaleCache[id], hit.source === image, hit.maxSide == maxSide {
            return hit.image
        }
        let side = max(image.width, image.height)
        let ratio = maxSide / CGFloat(side)
        let newW = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let newH = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard CGFloat(side) > maxSide else {
            prescaleCache[id] = (image, maxSide, image)
            return image
        }
        // CG 高质量插值（96MP→4096 实测 ~90ms）而非 Lanczos/CI（~200ms+ 且
        // 产物是 CI 延迟渲染位图，下游 clip/draw 会触发 CI 管线）。显示预览
        // 的清晰度差异在这个比例下不可辨；导出走全分辨率不经此处。
        let sctx = CGContext(data: nil, width: newW, height: newH,
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let sctx else {
            prescaleCache[id] = (image, maxSide, image)
            return image
        }
        sctx.interpolationQuality = .high
        sctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
        let small = sctx.makeImage() ?? image
        prescaleCache[id] = (image, maxSide, small)
        return small
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
                       clipRect: CGRect? = nil,
                       contentOffset: CGSize = .zero) -> CGImage? {
        guard let ctx = drawingContext(base) else { return nil }
        // 图层偏移：调用方传的是文档像素，落到位图上要减去偏移。
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        let radius = max(0.5, size / 2)
        let spacing = max(0.6, radius * 0.22)
        let stampPoints = Self.stampPoints(points, spacing: spacing)
        // 矩形选区直 clip（零蒙版成本）；其它选区形状走 maskedBlend 路径。
        // 调用方约定：clipRectNonZero != nil 时 clipMask 必为 nil。
        if let clipRect = clipRect {
            ctx.clip(to: clipRect)
        }
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
              mask.width == w, mask.height == h else { return nil }
        // CGContext 原生混合（旧实现：384MB×3 字节数组 + 逐像素 Double 循环，
        // Debug 构建实测 ~1.5s；现：三次 drawImage + luminance→alpha 蒙版，
        // 96MP ~120ms，且 -O0/-O 差距小）。方向核对（灰度蒙版 + 翻转上下文
        // 组合曾踩位移坑）：clip(to:mask:) 的 mask 走当前 CTM，本函数不翻转
        // CTM、base 与 mask 同为 top-down 位图 → 直接用，选区落点像素级验证过。
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 1) 底图
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        // 2) 灰度蒙版 → alpha 蒙版（白 = 显示 effect）。CIMaskToAlpha 语义 =
        //    luminance → alpha；显式预翻转不需要（context 未翻转，与蒙版同向）。
        guard let alphaMask = alphaMask(from: mask, preFlip: false) else { return nil }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                 mask: alphaMask)
        ctx.draw(effect, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.restoreGState()
        return ctx.makeImage()
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
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
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
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
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
    /// alpha 蒙版转换缓存：`CGContextClipToMask` 每次都要把整幅蒙版走
    /// A8→RGBA 转换（96MP ~350ms，sample 实测 maskedBlend 的大头），而一次
    /// 笔画序列里蒙版对象不变。key = 灰度蒙版 CGImage 身份 + preFlip。
    private static var alphaMaskCache: [(mask: CGImage, preFlip: Bool, alpha: CGImage)] = []
    private static let alphaMaskCacheLock = NSLock()

    /// `preFlip: false` = 供未翻转上下文的 `clip(to:mask:)` 使用（maskedBlend：
    /// 该 ctx 直接 draw top-down 位图、不翻转 CTM，蒙版必须与图像同向）；
    /// 缺省 true = 供 y 翻转的绘制上下文（历史行为）。
    static func alphaMask(from gray: CGImage, preFlip: Bool = true) -> CGImage? {
        alphaMaskCacheLock.lock()
        for hit in alphaMaskCache where hit.mask === gray && hit.preFlip == preFlip {
            alphaMaskCacheLock.unlock()
            return hit.alpha
        }
        alphaMaskCacheLock.unlock()
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
        // clip(to:mask:) 会跟着当前 CTM 走：y 翻转的绘制上下文需要蒙版
        // 预翻转（否则选区镜像到另一半，实测踩过）；未翻转 ctx（maskedBlend）
        // 必须拿同向蒙版。
        let unmaterialized = preFlip ? (flippedVertically(alpha) ?? alpha) : alpha
        // 物化：alphaMask 的底层是 CIContext 的延迟渲染产物（CIImage 回写），
        // CGContextClipToMask 第一次用时才触发整条 CI 渲染管线（sample 实测
        // clip 内 192 帧在 CI::RenderToBitmap）——物化成纯位图让 clip 走
        // 普通位图 blit，且结果可被缓存复用。
        let result = materialized(unmaterialized) ?? unmaterialized
        alphaMaskCacheLock.lock()
        alphaMaskCache.append((gray, preFlip, result))
        // 蒙版是全图大小（96MP ≈ 96MB alpha）——只留 2 个（当前 + 上一选区），
        // 否则长会话内存压力把每笔拖进换页（实测 6.7GB RSS 时单笔 2s+）。
        if alphaMaskCache.count > 2 { alphaMaskCache.removeFirst(alphaMaskCache.count - 2) }
        alphaMaskCacheLock.unlock()
        return result
    }

    /// 把（可能由 CI 延迟渲染支撑的）CGImage 物化成纯 CGContext 位图。
    static func materialized(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
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
                          cornerRadius: CGFloat = 0, dashed: Bool = false,
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
        if dashed {
            ctx.setLineDash(phase: 0, lengths: [max(2, lineWidth * 2.5),
                                                max(2, lineWidth * 1.8)])
        }
        switch shape {
        case .rectangle, .ellipse:
            let path = shape == .rectangle && cornerRadius > 0
                ? CGPath(roundedRect: rect, cornerWidth: min(cornerRadius, rect.width / 2),
                         cornerHeight: min(cornerRadius, rect.height / 2), transform: nil)
                : CGPath(rect: rect, transform: nil)
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

    // MARK: - 文字（v0.8.46 迭代 3：多行/字重/对齐/行距/描边/阴影/背景框）

    nonisolated struct TextStyle {
        var fontName: String?
        var weight: String = "semibold"   // regular/medium/semibold/bold/heavy
        var fontSize: CGFloat = 32
        var color: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        var alignment: String = "left"    // left/center/right
        var lineSpacing: CGFloat = 1.2    // 行高倍数
        var strokeWidth: CGFloat = 0      // 0 = 无描边（字号的百分比换算）
        var strokeColor: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        var shadow: Bool = false
        var shadowColor: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
        var backgroundColor: CGColor?     // 非空 = 文字底板
        var padding: CGFloat = 14
        var cornerRadius: CGFloat = 8

        func nsWeight() -> NSFont.Weight {
            switch weight {
            case "regular": return .regular
            case "medium": return .medium
            case "bold": return .bold
            case "heavy": return .heavy
            default: return .semibold
            }
        }
    }

    static func drawText(_ base: CGImage, text: String, at anchor: CGPoint,
                         style: TextStyle,
                         contentOffset: CGSize = .zero) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        guard let ctx = drawingContext(base) else { return nil }
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        let fontSize = max(4, style.fontSize)
        let font = style.fontName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.systemFont(ofSize: fontSize, weight: style.nsWeight())
        let paragraph = NSMutableParagraphStyle()
        switch style.alignment {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        paragraph.lineHeightMultiple = max(0.8, style.lineSpacing)
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: style.color) ?? .white,
            .paragraphStyle: paragraph,
        ]
        if style.strokeWidth > 0 {
            // 负值 = 填充 + 描边；单位是字号百分比
            attributes[.strokeWidth] = -(style.strokeWidth / fontSize * 100)
            attributes[.strokeColor] = NSColor(cgColor: style.strokeColor) ?? .black
        }
        if style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(cgColor: style.shadowColor) ?? .black
            shadow.shadowBlurRadius = max(1, fontSize * 0.08)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize * 0.06))
            attributes[.shadow] = shadow
        }
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)
        let maxWidth = max(32, CGFloat(base.width) - anchor.x - style.padding * 2)
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        // 对齐后的文字横向起点（背景框必须跟着文字，而不是跟着布局框）
        let textX: CGFloat
        switch style.alignment {
        case "center": textX = anchor.x + max(0, (maxWidth - bounds.width) / 2)
        case "right": textX = anchor.x + max(0, maxWidth - bounds.width)
        default: textX = anchor.x
        }
        if let background = style.backgroundColor {
            let rect = CGRect(x: textX - style.padding,
                              y: anchor.y - style.padding,
                              width: min(maxWidth, bounds.width) + style.padding * 2,
                              height: bounds.height + style.padding * 2)
            ctx.setFillColor(background)
            ctx.addPath(CGPath(roundedRect: rect,
                               cornerWidth: style.cornerRadius,
                               cornerHeight: style.cornerRadius,
                               transform: nil))
            ctx.fillPath()
        }
        attributed.draw(with: CGRect(x: anchor.x, y: anchor.y,
                                     width: maxWidth, height: bounds.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// 兼容旧签名（单行/系统字体）。
    static func drawText(_ base: CGImage, text: String, at anchor: CGPoint,
                         fontSize: CGFloat, color: CGColor,
                         fontName: String? = nil,
                         contentOffset: CGSize = .zero) -> CGImage? {
        var style = TextStyle()
        style.fontSize = fontSize
        style.color = color
        style.fontName = fontName
        return drawText(base, text: text, at: anchor, style: style,
                        contentOffset: contentOffset)
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
    // MARK: - 文字层（可再编辑）

    /// 规格 → 渲染样式（hex → CGColor）。
    static func textStyle(from spec: ImageTextSpec) -> TextStyle {
        var style = TextStyle()
        style.fontName = spec.fontName
        style.weight = spec.weight
        style.fontSize = CGFloat(spec.fontSize)
        if let c = color(from: spec.colorHex) { style.color = c }
        style.alignment = spec.alignment
        style.lineSpacing = CGFloat(spec.lineSpacing)
        style.strokeWidth = CGFloat(spec.strokeWidth)
        if let c = color(from: spec.strokeColorHex) { style.strokeColor = c }
        style.shadow = spec.shadow
        if let hex = spec.backgroundHex, let c = color(from: hex) {
            style.backgroundColor = c
        }
        return style
    }

    /// 在画布尺寸的透明位图上渲染文字（= 文字层位图）。
    static func renderTextLayer(_ spec: ImageTextSpec, canvasSize: CGSize) -> CGImage? {
        guard let base = transparent(size: canvasSize) else { return nil }
        return drawText(base, text: spec.text, at: spec.anchor,
                        style: textStyle(from: spec), contentOffset: .zero)
    }

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

// MARK: - 修饰工具（迭代 7：全部用绘制/CIImage 语义，不碰原始 buffer）

nonisolated extension ImageEditorRaster {

    /// 软边圆形灰度蒙版（白 = 生效），峰值 alpha 由 strength 控制。
    static func softMask(size: CGSize, center: CGPoint, radius: CGFloat,
                         strength: Double) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        // 文档 y-down → CG y-up
        let c = CGPoint(x: center.x, y: CGFloat(h) - center.y)
        let peak = CGFloat(max(0, min(1, strength)))
        let space = CGColorSpaceCreateDeviceGray()
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(gray: peak, alpha: 1),
                                                 CGColor(gray: peak, alpha: 1),
                                                 CGColor(gray: 0, alpha: 1)] as CFArray,
                                        locations: [0, 0.7, 1]) else { return nil }
        let r = max(1, radius)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: r, options: [])
        return ctx.makeImage()
    }

    /// 一次修饰戳：生成"效果图"，再用软边圆蒙版混回。输入文档像素坐标。
    static func retouch(_ base: CGImage, mode: ImageRetouchMode,
                        at point: CGPoint, radius: CGFloat,
                        strength: Double, source: CGPoint? = nil) -> CGImage? {
        let size = CGSize(width: base.width, height: base.height)
        guard let mask = softMask(size: size, center: point, radius: radius,
                                  strength: strength) else { return nil }
        let effect: CGImage?
        switch mode {
        case .clone, .heal:
            guard let source else { return base }
            let w = base.width, h = base.height
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            // 把 base 平移，使 source 区域落到 point：draw 在 y-up 里，文档 dy 取反。
            let dx = point.x - source.x
            let dy = point.y - source.y
            ctx.draw(base, in: CGRect(x: dx, y: -dy,
                                      width: CGFloat(w), height: CGFloat(h)))
            effect = ctx.makeImage()
        case .dodge, .burn:
            effect = adjustedBrightness(base, amount: mode == .dodge ? 0.35 : -0.35)
        case .blur:
            effect = blurred(base, radius: max(1, radius * 0.35))
        case .sharpen:
            effect = sharpened(base, amount: 0.8)
        }
        guard let effect else { return base }
        return maskedBlend(base: base, effect: effect, mask: mask) ?? base
    }

    private static func adjustedBrightness(_ image: CGImage, amount: Double) -> CGImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputBrightnessKey)
        guard let output = filter.outputImage else { return nil }
        return ImagePipelineRenderer.context.createCGImage(output, from: output.extent)
    }

    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return ImagePipelineRenderer.context.createCGImage(
            output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func sharpened(_ image: CGImage, amount: Double) -> CGImage? {
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputSharpnessKey)
        guard let output = filter.outputImage else { return nil }
        return ImagePipelineRenderer.context.createCGImage(output, from: output.extent)
    }
}

// MARK: - 渐变（迭代 8）

nonisolated extension ImageEditorRaster {

    /// 在 base 上绘制线性/径向渐变（文档像素坐标，可被选区裁剪）。
    static func drawGradient(_ base: CGImage, from: CGPoint, to: CGPoint,
                             colors: [CGColor], radial: Bool,
                             clipMask: CGImage?, contentOffset: CGSize = .zero) -> CGImage? {
        guard colors.count >= 2,
              let ctx = drawingContext(base) else { return nil }
        if contentOffset != .zero {
            ctx.translateBy(x: -contentOffset.width, y: -contentOffset.height)
        }
        ctx.saveGState()
        // 选区裁剪：蒙版是 y-down 文档坐标，绘制上下文是 y-down（翻转后）
        if let clipMask, let alpha = alphaMask(from: clipMask) {
            ctx.clip(to: CGRect(x: 0, y: 0, width: base.width, height: base.height),
                     mask: alpha)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: nil) else { return base }
        if radial {
            ctx.drawRadialGradient(gradient, startCenter: from, startRadius: 0,
                                   endCenter: to, endRadius: max(1, hypot(to.x - from.x,
                                                                         to.y - from.y)),
                                   options: [.drawsAfterEndLocation])
        } else {
            ctx.drawLinearGradient(gradient, start: from, end: to,
                                   options: [.drawsBeforeStartLocation,
                                             .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

// MARK: - 图层样式（迭代 9：剪影只在图层有透明像素时才有意义）

nonisolated extension ImageEditorRaster {

    static func silhouette(_ bitmap: CGImage) -> CGImage? {
        let w = bitmap.width, h = bitmap.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.setBlendMode(.destinationIn)
        ctx.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    static func colorized(_ mask: CGImage, color: CGColor) -> CGImage? {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.setBlendMode(.destinationIn)
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    static func styled(_ bitmap: CGImage, style: ImageLayerStyle) -> CGImage? {
        guard style.isActive else { return bitmap }
        let w = bitmap.width, h = bitmap.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let mask = silhouette(bitmap) else { return bitmap }

        func blurred(_ image: CGImage, radius: Double) -> CGImage? {
            guard radius > 0.1, let filter = CIFilter(name: "CIGaussianBlur") else { return image }
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            guard let out = filter.outputImage else { return image }
            return ImagePipelineRenderer.context.createCGImage(out, from: bounds)
        }
        func dilated(_ image: CGImage, radius: Double) -> CGImage? {
            guard radius > 0.1, let filter = CIFilter(name: "CIMorphologyMaximum") else { return image }
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            guard let out = filter.outputImage else { return image }
            return ImagePipelineRenderer.context.createCGImage(out, from: bounds)
        }
        func drawImage(_ image: CGImage?, dx: Double = 0, dy: Double = 0) {
            guard let image else { return }
            ctx.draw(image, in: bounds.offsetBy(dx: dx, dy: -dy))
        }

        if style.glowEnabled, let color = color(from: style.glowColor) {
            let base = colorized(mask, color: color) ?? mask
            drawImage(blurred(base, radius: style.glowRadius))
        }
        if style.shadowEnabled, let color = color(from: style.shadowColor) {
            let base = colorized(mask, color: color) ?? mask
            drawImage(blurred(base, radius: style.shadowRadius),
                      dx: style.shadowOffsetX, dy: style.shadowOffsetY)
        }
        if style.strokeEnabled, let color = color(from: style.strokeColor) {
            drawImage(colorized(dilated(mask, radius: style.strokeWidth) ?? mask,
                                color: color))
        }
        ctx.draw(bitmap, in: bounds)
        return ctx.makeImage()
    }
}

// MARK: - 直方图（迭代 16）

nonisolated extension ImageEditorRaster {

    /// RGB 三通道直方图（256 桶，步进采样大图）。
    static func histogram(_ image: CGImage) -> (r: [Int], g: [Int], b: [Int])? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let data = ctx.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        let step = max(1, (w * h) / 200_000)
        var index = 0
        while index < w * h {
            let o = index * 4
            r[Int(buffer[o])] += 1
            g[Int(buffer[o + 1])] += 1
            b[Int(buffer[o + 2])] += 1
            index += step
        }
        return (r, g, b)
    }
}
