import AppKit
import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// 照片滤镜预设（v0.8.27 媒体批）：none=原图（不参与烙印），其余一键套用。
nonisolated enum ImageFilterPreset: String, CaseIterable, Identifiable {
    case none, vivid, mono, chrome, fade, instant, noir, process, tonal, transfer

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .none: return String(localized: "Original")
        case .vivid: return String(localized: "Vivid")
        case .mono: return String(localized: "Mono")
        case .chrome: return String(localized: "Chrome")
        case .fade: return String(localized: "Fade")
        case .instant: return String(localized: "Instant")
        case .noir: return String(localized: "Noir")
        case .process: return String(localized: "Process")
        case .tonal: return String(localized: "Tonal")
        case .transfer: return String(localized: "Transfer")
        }
    }

    var ciFilterName: String? {
        switch self {
        case .none: return nil
        case .vivid: return "CIVibrance"
        case .mono: return "CIPhotoEffectMono"
        case .chrome: return "CIPhotoEffectChrome"
        case .fade: return "CIPhotoEffectFade"
        case .instant: return "CIPhotoEffectInstant"
        case .noir: return "CIPhotoEffectNoir"
        case .process: return "CIPhotoEffectProcess"
        case .tonal: return "CIPhotoEffectTonal"
        case .transfer: return "CIPhotoEffectTransfer"
        }
    }
}

/// 图片编辑变换核（v0.8.12 旗舰 D，19）：旋转/翻转/裁剪/缩放——
/// 纯 CoreGraphics 位图操作，零第三方依赖。标注（20）在视图层用
/// CAShapeLayer/PencilKit 叠加，导出时烙进位图（flatten）。
/// 全部函数值语义：输入 CGImage 返回新 CGImage（不修改原图）。
nonisolated enum ImageTransforms {
    /// 旋转 90°（顺时针 clockwise，否则逆时针）。宽高互换。
    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        let newW = h, newH = w
        guard let context = ImagePixelFormat.of(image).makeContext(width: newW, height: newH)
        else { return nil }
        context.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        if clockwise {
            context.rotate(by: -.pi / 2)
        } else {
            context.rotate(by: .pi / 2)
        }
        context.translateBy(x: CGFloat(w) / -2, y: CGFloat(h) / -2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 翻转（horizontal = 左右镜像，否则上下）。
    static func flipped(_ image: CGImage, horizontal: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = ImagePixelFormat.of(image).makeContext(width: w, height: h)
        else { return nil }
        if horizontal {
            context.concatenate(CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: CGFloat(-w), y: 0))
        } else {
            context.concatenate(CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: CGFloat(-h)))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 裁剪（矩形为像素坐标，origin 在左上——调用方从视图坐标换算）。
    static func cropped(_ image: CGImage, rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        // CG 原点在左下；视图给的是左上原点 → y 翻转。
        let cgRect = CGRect(x: clamped.origin.x,
                            y: CGFloat(image.height) - clamped.maxY,
                            width: clamped.width, height: clamped.height)
        return image.cropping(to: cgRect)
    }

    /// 尺寸调整（Lanczos 由 CoreImage 提供——高质量缩放）。
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(Double(width) / Double(image.width), forKey: kCIInputScaleKey)
        filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter?.outputImage else { return nil }
        // 显式按源格式渲染（RGBA16 + 源色域）——裸 createCGImage 是 8 位 sRGB。
        let format = ImagePixelFormat.of(image)
        let context = CIContext(options: format.ciContextOptions)
        return format.render(output, from: output.extent, using: context)
    }

    /// 标注层烙进位图：annotation 为已渲染的位图（视图层把 PencilKit/形状
    /// 画进临时 CGContext），叠在原图上（同尺寸）。
    static func flattened(_ image: CGImage, overlay: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = ImagePixelFormat.of(image).makeContext(width: w, height: h)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 调色（21）：CIColorControls——亮度/对比度/饱和度 + 锐化（CISharpenLuminance）
    /// + 曝光（CIExposureAdjust）+ 色温（CITemperatureAndTint，v0.8.27 媒体批）。
    /// temperature 滑杆 -100…100：正值偏暖（neutral 6500→4000），负值偏冷。
    static func adjusted(_ image: CGImage, brightness: Double, contrast: Double,
                         saturation: Double, sharpen: Double,
                         exposure: Double = 0, temperature: Double = 0) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(ciImage, forKey: kCIInputImageKey)
        controls.setValue(brightness, forKey: kCIInputBrightnessKey)
        controls.setValue(contrast, forKey: kCIInputContrastKey)
        controls.setValue(saturation, forKey: kCIInputSaturationKey)
        var output = controls.outputImage
        if exposure != 0, let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(output, forKey: kCIInputImageKey)
            exposureFilter.setValue(exposure, forKey: kCIInputEVKey)
            output = exposureFilter.outputImage ?? output
        }
        if temperature != 0, let tint = CIFilter(name: "CITemperatureAndTint") {
            tint.setValue(output, forKey: kCIInputImageKey)
            tint.setValue(6500 - temperature * 25, forKey: "inputNeutral")
            tint.setValue(6500, forKey: "inputTargetNeutral")
            output = tint.outputImage ?? output
        }
        if sharpen > 0, let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(output, forKey: kCIInputImageKey)
            sharpenFilter.setValue(sharpen, forKey: "inputSharpness")
            output = sharpenFilter.outputImage
        }
        guard let output else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// 拉直（v0.8.41）：任意角度旋转后放大填充原尺寸（无黑角），
    /// 输出尺寸与输入一致（居中裁切语义）。
    static func straightened(_ image: CGImage, degrees: Double) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let radians = degrees * Double.pi / 180
        let sinA = abs(CGFloat(sin(radians)))
        let cosA = abs(CGFloat(cos(radians)))
        // 覆盖原矩形的缩放：旋转后的包围盒必须盖住 w×h。
        let scaleX = (w * cosA + h * sinA) / w
        let scaleY = (w * sinA + h * cosA) / h
        let scale = max(scaleX, scaleY)
        guard let context = ImagePixelFormat.of(image).makeContext(
            width: image.width, height: image.height)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: w / 2, y: h / 2)
        context.rotate(by: CGFloat(radians))
        context.scaleBy(x: scale, y: scale)
        // CGContext 坐标系 y 向上；居中绘制即可。
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return context.makeImage()
    }

    /// 滤镜预设（v0.8.27 媒体批）：系统 CIPhotoEffect 家族 + 鲜艳（CIVibrance）。
    static func photoFiltered(_ image: CGImage, preset: ImageFilterPreset) -> CGImage? {
        guard let name = preset.ciFilterName else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        if preset == .vivid { filter.setValue(0.8, forKey: "inputAmount") }
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    // MARK: - 编解码（含 .bak 快照语义由调用方处理）

    /// 加载：显式走 ImageIO。`NSImage(contentsOf:)` 会在解码阶段把 16 位 /
    /// 广色域源图降成 8 位 sRGB（v0.8.85 批 1 实测：16 bpc Display P3 PNG
    /// 经 NSImage 读回 8 bpc）。EXIF 方向维持原行为（不自动旋转）。
    static func load(from url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(
               source, 0,
               [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return image
        }
        return NSImage(contentsOf: url)?.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
    }

    /// 写回（旧签名包装）：默认配置 = 跟随源图、保留元数据。
    static func save(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        var options = ImageSaveOptions.default
        options.quality = quality
        try save(image, to: url, options: options, sourceProperties: nil)
    }

    /// 写回（v0.8.85 批 1）：目标配置/位深/DPI/元数据策略。
    /// **不再经 NSBitmapImageRep**——它把 16 位与广色域静默降成 8 位 sRGB；
    /// 现在统一 CGImageDestination，位深与 ICC 跟随输出 CGImage 的色域。
    /// 容器限制：jpg/webp/heic 只有 8 位（`supportsDeepColor`）。
    static func save(_ image: CGImage, to url: URL,
                     options: ImageSaveOptions,
                     sourceProperties: [CFString: Any]?) throws {
        let ext = url.pathExtension.lowercased()
        // 1) 目标格式：profile/位深（容器限制：jpg/webp/heic 8 位）
        let sourceFormat = ImagePixelFormat.of(image)
        var target = sourceFormat
        if let space = options.profile.cgColorSpace {
            target.space = ImagePixelFormat.WorkingSpace.inferred(from: space)
        }
        let wants16 = (options.bitDepth ?? sourceFormat.bitDepth) >= 16
        let deepOK = ImageSaveOptions.supportsDeepColor(ext)
        let depth = deepOK && wants16 ? 16 : 8
        target.bitDepth = depth
        // 2) 需要转换就先进目标上下文（16 位转换高质量且保色彩）
        var output = image
        let sourceDepth = max(8, min(16, image.bitsPerComponent))
        if target.space != sourceFormat.space || depth != sourceDepth,
           let ctx = target.makeContext(width: image.width, height: image.height) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let converted = ctx.makeImage() { output = converted }
        }
        // 3) 元数据：保留（可去 GPS）/ 清除；DPI 覆盖
        var properties: [CFString: Any] = [:]
        if let sourceProperties, options.metadata != .stripAll {
            var props = sourceProperties
            props.removeValue(forKey: kCGImagePropertyPixelWidth)
            props.removeValue(forKey: kCGImagePropertyPixelHeight)
            if options.metadata == .stripGPS {
                props.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }
            properties = props
        }
        if let dpi = options.dpi, dpi > 0 {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        if ["jpg", "jpeg", "webp", "heic", "heif"].contains(ext) {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        // 4) 编码：CGImageDestination 保位深与 ICC（跟着 output 的色域走）
        let uti: CFString
        switch ext {
        case "jpg", "jpeg": uti = UTType.jpeg.identifier as CFString
        case "tiff", "tif": uti = UTType.tiff.identifier as CFString
        case "heic", "heif": uti = UTType.heic.identifier as CFString
        case "webp": uti = UTType.webP.identifier as CFString
        default: uti = UTType.png.identifier as CFString
        }
        guard let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(
                  data, uti, 1, nil) else {
            throw NSError(domain: "ImageTransforms", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "destination creation failed"])
        }
        CGImageDestinationAddImage(dest, output,
                                   properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageTransforms", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "encode failed (\(ext))"])
        }
        try (data as Data).write(to: url, options: .atomic)
    }
}
