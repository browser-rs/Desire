import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 管线渲染器（v0.8.41）：把 `ImageEditPipeline` 的 adjust/filter/selection
/// 应用到一张基础位图上。纯函数：输入 CGImage + 管线 → 输出 CGImage。
/// 渲染走共享 CIContext；选区 = 调节/滤镜结果用羽化蒙版混回原图。
nonisolated enum ImagePipelineRenderer {
    nonisolated static let context = CIContext(options: [
        .cacheIntermediates: false,
    ])

    static func render(base: CGImage, pipeline: ImageEditPipeline) -> CGImage? {
        var current = base
        var selection: ImageSelectionParams?
        for operation in pipeline.operations where operation.isEnabled {
            switch operation.kind {
            case .selection:
                guard let params = operation.selection else { continue }
                selection = params.isNeutral ? nil : params
            case .geometry:
                guard let action = operation.geometryAction else { continue }
                switch action {
                case .rotate90cw:
                    current = ImageTransforms.rotated(current, clockwise: true)
                        ?? current
                case .rotate90ccw:
                    current = ImageTransforms.rotated(current, clockwise: false)
                        ?? current
                case .flipH:
                    current = ImageTransforms.flipped(current, horizontal: true)
                        ?? current
                case .flipV:
                    current = ImageTransforms.flipped(current, horizontal: false)
                        ?? current
                }
            case .adjust:
                guard let params = operation.adjust, !params.isNeutral else { continue }
                let adjusted = renderAdjustments(current, params: params)
                    ?? current
                current = compositeSelective(base: current, effect: adjusted,
                                             selection: selection)
            case .filter:
                guard let name = operation.filter,
                      let preset = ImageFilterPreset(rawValue: name), preset != .none
                else { continue }
                let filtered = ImageTransforms.photoFiltered(current, preset: preset)
                current = compositeSelective(base: current,
                                             effect: filtered ?? current,
                                             selection: selection)
            }
        }
        return current
    }

    // MARK: - 调节链

    private static func renderAdjustments(
        _ image: CGImage, params: ImageAdjustParams
    ) -> CGImage? {
        var ci = CIImage(cgImage: image)

        // 白平衡（色温/色调）放在最前，后续对比/曝光在"白平衡后"的画面上工作。
        if params.temperature != 0 || params.tint != 0 {
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(ci, forKey: kCIInputImageKey)
                filter.setValue(6500 - params.temperature * 25, forKey: "inputNeutral")
                filter.setValue(6500 + params.tint * 30, forKey: "inputTargetNeutral")
                ci = filter.outputImage ?? ci
            }
        }
        if params.exposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.exposure, forKey: kCIInputEVKey)
            ci = filter.outputImage ?? ci
        }
        if params.highlights != 0 || params.shadows != 0,
           let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            // 正 highlights = 提亮高光（inputHighlightAmount 默认 1，>1 提亮）
            filter.setValue(1 + params.highlights, forKey: "inputHighlightAmount")
            // 正 shadows = 提亮阴影（inputShadowAmount 默认 -1，0 = 中性提亮）
            filter.setValue(-1 + params.shadows, forKey: "inputShadowAmount")
            ci = filter.outputImage ?? ci
        }
        if params.hasChannelCurves, let cube = channelCurveFilter(ci, params: params) {
            ci = cube
        } else if let curve = toneCurveFilter(ci, params: params) {
            ci = curve
        }
        if params.blackPoint > 0 || params.whitePoint < 1 || params.gamma != 1,
           let filter = CIFilter(name: "CIToneCurve") {
            let black = params.blackPoint
            let white = params.whitePoint
            let span = max(0.000_001, white - black)
            // 线性映射：黑点→0，中点→gamma 调整后，白点→1
            // gamma > 1 提亮中间调（0.5^(1/gamma) 上移），<1 压暗。
            let midY = pow(0.5, 1.0 / max(0.1, params.gamma))
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            filter.setValue(CIVector(x: black + span * 0.5,
                                     y: midY), forKey: "inputPoint1")
            filter.setValue(CIVector(x: white, y: 1), forKey: "inputPoint2")
            ci = filter.outputImage ?? ci
        }
        if params.saturation != 1 || params.brightness != 0 || params.contrast != 1,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(params.contrast, forKey: kCIInputContrastKey)
            filter.setValue(params.saturation, forKey: kCIInputSaturationKey)
            ci = filter.outputImage ?? ci
        }
        if params.vibrance != 0, let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.vibrance, forKey: "inputAmount")
            ci = filter.outputImage ?? ci
        }
        // 色彩平衡（v0.8.54 批 3）：R/G/B 通道独立偏移。
        if params.redBalance != 0 || params.greenBalance != 0 || params.blueBalance != 0,
           let filter = CIFilter(name: "CIColorMatrix") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 1, y: 0, z: 0, w: params.redBalance), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 1, z: 0, w: params.greenBalance), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 1, w: params.blueBalance), forKey: "inputBVector")
            ci = filter.outputImage ?? ci
        }
        if params.clarity > 0, let filter = CIFilter(name: "CIUnsharpMask") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(12.0, forKey: kCIInputRadiusKey)
            filter.setValue(params.clarity, forKey: kCIInputIntensityKey)
            ci = filter.outputImage ?? ci
        }
        if params.sharpen > 0, let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.sharpen, forKey: "inputSharpness")
            ci = filter.outputImage ?? ci
        }
        if params.denoise > 0, let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.denoise * 0.1, forKey: "inputNoiseLevel")
            filter.setValue(params.denoise * 0.4, forKey: "inputSharpness")
            ci = filter.outputImage ?? ci
        }
        if params.vignette > 0, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.vignette * 2, forKey: "inputIntensity")
            let radius = max(1.0, 2.0 - params.vignetteFeather * 1.5)
            filter.setValue(radius, forKey: "inputRadius")
            ci = filter.outputImage ?? ci
        }
        return context.createCGImage(ci, from: ci.extent)
    }

    /// 分通道曲线：按曲线生成 RGB 立方 LUT（CIColorCube），通道独立映射。
    private static func channelCurveFilter(
        _ input: CIImage, params: ImageAdjustParams
    ) -> CIImage? {
        let dimension = 32
        var lattice: [Float] = []
        lattice.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension {
            let y = Double(b) / Double(dimension - 1)
            let gValue = ImageAdjustParams.curveValue(params.curveGreen, at: y)
            for g in 0..<dimension {
                let v = Double(g) / Double(dimension - 1)
                let rValue = ImageAdjustParams.curveValue(params.curveRed, at: v)
                for r in 0..<dimension {
                    let u = Double(r) / Double(dimension - 1)
                    let bValue = ImageAdjustParams.curveValue(params.curveBlue, at: u)
                    lattice.append(Float(rValue))
                    lattice.append(Float(gValue))
                    lattice.append(Float(bValue))
                    lattice.append(1)
                }
            }
        }
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(Data(bytes: lattice, count: lattice.count * 4),
                        forKey: "inputCubeData")
        return filter.outputImage
    }

    /// RGB 曲线（CIToneCurve，≤5 个控制点）。
    private static func toneCurveFilter(
        _ input: CIImage, params: ImageAdjustParams
    ) -> CIImage? {
        guard params.hasCurve, let filter = CIFilter(name: "CIToneCurve") else {
            return nil
        }
        let points = params.curvePoints.prefix(5)
        filter.setValue(input, forKey: kCIInputImageKey)
        for (index, point) in points.enumerated() {
            filter.setValue(CIVector(x: point.x, y: point.y),
                            forKey: "inputPoint\(index)")
        }
        return filter.outputImage
    }

    // MARK: - 选区合成

    /// 有选区时：效果层用羽化蒙版混回基础层；无选区直接返回效果层。
    private static func compositeSelective(
        base: CGImage, effect: CGImage, selection: ImageSelectionParams?
    ) -> CGImage {
        guard let selection else { return effect }
        guard let mask = selectionMask(selection, size: CGSize(width: base.width,
                                                               height: base.height))
        else { return effect }
        let effectCI = CIImage(cgImage: effect)
        let baseCI = CIImage(cgImage: base)
        let maskCI = CIImage(cgImage: mask)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return effect }
        blend.setValue(effectCI, forKey: kCIInputImageKey)
        blend.setValue(baseCI, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return effect }
        return context.createCGImage(output, from: output.extent) ?? effect
    }

    /// 选区蒙版：白 = 应用效果，黑 = 保持原样；feather 用高斯模糊实现。
    private static func selectionMask(
        _ selection: ImageSelectionParams, size: CGSize
    ) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        // 归一化 y 以图像顶部为 0（与视图坐标一致）；CGContext 原点在左下。
        let rect = CGRect(x: selection.x * size.width,
                          y: (1 - selection.y - selection.height) * size.height,
                          width: selection.width * size.width,
                          height: selection.height * size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        if selection.ellipse {
            context.fillEllipse(in: rect)
        } else {
            context.fill(rect)
        }
        guard let sharp = context.makeImage() else { return nil }
        guard selection.feather > 0 else { return sharp }
        let radius = selection.feather * Double(min(width, height)) * 0.5
        guard radius > 0.5,
              let blur = CIFilter(name: "CIGaussianBlur") else { return sharp }
        blur.setValue(CIImage(cgImage: sharp), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage else { return sharp }
        return Self.context.createCGImage(
            blurred, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}


// MARK: - 自定义蒙版渲染（迭代 2：套索 / 魔棒）

nonisolated extension ImagePipelineRenderer {
    /// 魔棒 CGImage 蒙版 + 效果混回。
    static func renderWithCustomMask(
        base: CGImage, pipeline: ImageEditPipeline, mask: CGImage
    ) -> CGImage? {
        guard let effect = render(base: base, pipeline: pipeline) else { return nil }
        let effectCI = CIImage(cgImage: effect)
        let baseCI = CIImage(cgImage: base)
        let maskCI = CIImage(cgImage: mask)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return effect }
        blend.setValue(effectCI, forKey: kCIInputImageKey)
        blend.setValue(baseCI, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return effect }
        return context.createCGImage(output, from: output.extent) ?? effect
    }

    /// 套索多边形蒙版 + 效果混回（含羽化）。
    static func renderWithLasso(
        base: CGImage, pipeline: ImageEditPipeline,
        vertices: [CGPoint], feather: Double
    ) -> CGImage? {
        guard let effect = render(base: base, pipeline: pipeline) else { return nil }
        let width = base.width
        let height = base.height
        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return effect }
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.beginPath()
        // 归一化顶点 → 像素（y 翻转：CG 原点左下）
        let pixelPoints = vertices.map { vertex in
            CGPoint(x: vertex.x * CGFloat(width),
                    y: (1 - vertex.y) * CGFloat(height))
        }
        maskContext.addLines(between: pixelPoints)
        maskContext.closePath()
        maskContext.fillPath()
        var mask = maskContext.makeImage()
        if feather > 0 {
            let radius = feather * Double(min(width, height)) * 0.5
            if radius > 0.5, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(CIImage(cgImage: mask!), forKey: kCIInputImageKey)
                blur.setValue(radius, forKey: kCIInputRadiusKey)
                if let blurred = blur.outputImage,
                   let final = context.createCGImage(blurred, from: CGRect(
                       x: 0, y: 0, width: width, height: height)) {
                    mask = final
                }
            }
        }
        guard let finalMask = mask else { return effect }
        let effectCI = CIImage(cgImage: effect)
        let baseCI = CIImage(cgImage: base)
        let maskCI = CIImage(cgImage: finalMask)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return effect }
        blend.setValue(effectCI, forKey: kCIInputImageKey)
        blend.setValue(baseCI, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return effect }
        return context.createCGImage(output, from: output.extent) ?? effect
    }
}
