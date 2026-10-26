import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// 图片编辑变换核（v0.8.12 旗舰 D，19）：旋转/翻转/裁剪/缩放——
/// 纯 CoreGraphics 位图操作，零第三方依赖。标注（20）在视图层用
/// CAShapeLayer/PencilKit 叠加，导出时烙进位图（flatten）。
/// 全部函数值语义：输入 CGImage 返回新 CGImage（不修改原图）。
nonisolated enum ImageTransforms {

    /// 旋转 90°（顺时针 clockwise，否则逆时针）。宽高互换。
    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        let newW = h, newH = w
        guard let context = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
        let context = CIContext()
        return context.createCGImage(output, from: output.extent)
    }

    /// 标注层烙进位图：annotation 为已渲染的位图（视图层把 PencilKit/形状
    /// 画进临时 CGContext），叠在原图上（同尺寸）。
    static func flattened(_ image: CGImage, overlay: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 调色（21）：CIColorControls——亮度/对比度/饱和度 + 锐化（CISharpenLuminance）。
    static func adjusted(_ image: CGImage, brightness: Double, contrast: Double,
                         saturation: Double, sharpen: Double) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(ciImage, forKey: kCIInputImageKey)
        controls.setValue(brightness, forKey: kCIInputBrightnessKey)
        controls.setValue(contrast, forKey: kCIInputContrastKey)
        controls.setValue(saturation, forKey: kCIInputSaturationKey)
        var output = controls.outputImage
        if sharpen > 0, let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(output, forKey: kCIInputImageKey)
            sharpenFilter.setValue(sharpen, forKey: "inputSharpness")
            output = sharpenFilter.outputImage
        }
        guard let output else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    // MARK: - 编解码（含 .bak 快照语义由调用方处理）

    static func load(from url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
    }

    /// 写回（atomically）：png / jpeg 由扩展名推断（heic 走 CoreImage——
    /// NSBitmapImageRep 无 HEIC 类型；失败回退 png）。
    static func save(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        let ext = url.pathExtension.lowercased()
        let data: Data
        switch ext {
        case "jpg", "jpeg":
            let rep = NSBitmapImageRep(cgImage: image)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                throw NSError(domain: "ImageTransforms", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "JPEG representation failed"])
            }
            data = jpeg
        case "heic":
            let ciImage = CIImage(cgImage: image)
            let context = CIContext()
            guard let heic = context.heifRepresentation(
                of: ciImage, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [CIImageRepresentationOption(rawValue: "kCIImageCompressionQuality"): quality]) else {
                throw NSError(domain: "ImageTransforms", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "HEIC representation failed"])
            }
            data = heic
        default:
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "ImageTransforms", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "PNG representation failed"])
            }
            data = png
        }
        try data.write(to: url, options: .atomic)
    }
}
