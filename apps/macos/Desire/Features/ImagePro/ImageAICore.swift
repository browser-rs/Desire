import CoreGraphics
import Foundation
import CoreImage
import Vision

/// AI 图片增强（迭代 3 · v0.8.43）：Vision 主体抠图 + 自动色阶/自动增强。
/// 纯 CPU；抠图结果 = 主体蒙版混合（前景原样、背景可选透明/纯色/模糊）。
nonisolated enum ImageAICore {

    // MARK: - 主体蒙版

    /// 生成前景实例蒙版（灰度 CGImage：白 = 前景）。
    static func subjectMask(_ image: CGImage) async -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let buffer: CVPixelBuffer?
        do {
            guard let first = request.results?.first else { return nil }
            buffer = try first.generateScaledMaskForImage(
                forInstances: first.allInstances,
                from: handler)
        } catch {
            return nil
        }
        guard let unwrapped = buffer else { return nil }
        let width = CVPixelBufferGetWidth(unwrapped)
        let height = CVPixelBufferGetHeight(unwrapped)
        CVPixelBufferLockBaseAddress(unwrapped, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(unwrapped, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(unwrapped),
              let maskContext = CGContext(
                  data: baseAddress, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(unwrapped),
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return maskContext.makeImage()
    }


    // MARK: - 抠图

    /// 抠图：蒙版内保留前景，外部替换为纯色。
    static func cutout(image: CGImage, mask: CGImage,
                       background: CGImage?) -> CGImage? {
        let effectCI = CIImage(cgImage: image)
        let maskCI = CIImage(cgImage: mask)
        let output: CIImage
        if let background {
            let bgCI = CIImage(cgImage: background)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
            blend.setValue(effectCI, forKey: kCIInputImageKey)
            blend.setValue(bgCI, forKey: kCIInputBackgroundImageKey)
            blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
            output = blend.outputImage ?? effectCI
        } else {
            // 透明底：CIBlendWithAlphaMask 用的是蒙版的 **alpha 通道**，而
            // subjectMask 是灰度蒙版（alpha 恒 1）→ 抠图结果整张不透明（实测
            // 导出 alpha 全 1）。改用 CIBlendWithMask（按亮度）+ 透明背景。
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: effectCI.extent)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
            blend.setValue(effectCI, forKey: kCIInputImageKey)
            blend.setValue(clear, forKey: kCIInputBackgroundImageKey)
            blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
            output = blend.outputImage ?? effectCI
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - 自动增强

    /// 自动色阶：直方图 1% 截断 → 拉伸黑/白点。
    static func autoLevels(_ image: CGImage) -> ImageAdjustParams {
        var params = ImageAdjustParams()
        let counts = histogramLuma(image)
        let total = counts.reduce(0, +)
        guard total > 0 else { return params }
        let cutoff = Int(Double(total) * 0.01)
        var blackIndex = 0
        var accumulated = 0
        for (index, count) in counts.enumerated() {
            accumulated += count
            if accumulated > cutoff { blackIndex = index; break }
        }
        var whiteIndex = 255
        accumulated = 0
        for (index, count) in counts.reversed().enumerated() {
            accumulated += count
            if accumulated > cutoff {
                whiteIndex = 255 - index
                break
            }
        }
        guard whiteIndex > blackIndex + 10 else { return params }
        params.blackPoint = (Double(blackIndex) / 255.0).clamped(0, 0.4)
        params.whitePoint = (Double(whiteIndex) / 255.0).clamped(0.6, 1)
        return params
    }

    /// 自动增强 = 自动色阶 + 轻微提饱和/清晰度（固定数值，安全档）。
    static func autoEnhance(_ image: CGImage) -> ImageAdjustParams {
        var params = autoLevels(image)
        params.saturation = 1.15
        params.clarity = 0.25
        params.sharpen = 0.4
        return ImageAdjustParams.clamped(params)
    }

    // MARK: - 直方图

    static func histogramLuma(_ image: CGImage) -> [Int] {
        let target = 128
        guard let context = CGContext(
            data: nil, width: target, height: target,
            bitsPerComponent: 8, bytesPerRow: target * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .init(repeating: 0, count: 256) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let data = context.data else {
            return .init(repeating: 0, count: 256)
        }
        let buffer = data.bindMemory(to: UInt8.self, capacity: target * target * 4)
        var counts = [Int](repeating: 0, count: 256)
        for index in 0..<(target * target) {
            let r = Double(buffer[index * 4])
            let g = Double(buffer[index * 4 + 1])
            let b = Double(buffer[index * 4 + 2])
            let luma = min(255, Int((0.299 * r + 0.587 * g + 0.114 * b).rounded()))
            counts[luma] += 1
        }
        return counts
    }
}
