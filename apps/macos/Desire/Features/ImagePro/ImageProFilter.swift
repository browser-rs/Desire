import CoreImage
import Foundation

/// ImagePro 专业滤镜（v0.8.54 专项）：CIFilter 创作滤镜族，非破坏挂在图层上。
/// 每个 filter = 名称 + 参数字典（radius/intensity/angle 等浮点键值对），
/// 管线渲染时经 `ImageProFilter.apply(ci:)` 转 CI 滤镜链。
nonisolated struct ImageProFilter: Codable, Equatable, Sendable {
    var kind: Kind
    var radius: Double = 10
    var intensity: Double = 0.5
    var angle: Double = 0

    nonisolated enum Kind: String, CaseIterable, Codable, Sendable {
        // 模糊
        case gaussianBlur, boxBlur, motionBlur, zoomBlur
        // 风格化
        case pixelate, crystallize, emboss, edgeWork
        // 扭曲
        case twirl, bump, glassLoops
        // 锐化
        case unsharpMask, highPass

        var localizedTitle: String {
            switch self {
            case .gaussianBlur: return String(localized: "Gaussian Blur")
            case .boxBlur: return String(localized: "Box Blur")
            case .motionBlur: return String(localized: "Motion Blur")
            case .zoomBlur: return String(localized: "Zoom Blur")
            case .pixelate: return String(localized: "Pixelate")
            case .crystallize: return String(localized: "Crystallize")
            case .emboss: return String(localized: "Emboss")
            case .edgeWork: return String(localized: "Edge Work")
            case .twirl: return String(localized: "Twirl")
            case .bump: return String(localized: "Bump")
            case .glassLoops: return String(localized: "Glass Loops")
            case .unsharpMask: return String(localized: "Unsharp Mask")
            case .highPass: return String(localized: "High Pass")
            }
        }

        /// 参数范围（UI 滑块用）。
        var radiusRange: ClosedRange<Double> {
            switch self {
            case .gaussianBlur: return 0...50
            case .boxBlur: return 1...50
            case .motionBlur: return 0...100
            case .zoomBlur: return 0...100
            case .pixelate: return 1...50
            case .crystallize: return 1...50
            case .emboss: return 0...10
            case .edgeWork: return 1...20
            case .twirl: return 0...3000
            case .bump: return 0...3000
            case .glassLoops: return 1...100
            case .unsharpMask: return 0...20
            case .highPass: return 1...20
            }
        }

        var defaultRadius: Double {
            switch self {
            case .gaussianBlur: return 8
            case .boxBlur: return 10
            case .motionBlur: return 20
            case .zoomBlur: return 20
            case .pixelate: return 8
            case .crystallize: return 10
            case .emboss: return 2
            case .edgeWork: return 5
            case .twirl: return 500
            case .bump: return 500
            case .glassLoops: return 20
            case .unsharpMask: return 5
            case .highPass: return 5
            }
        }
    }

    /// 应用到 CIImage（纯函数；pipeline 渲染时调用）。
    nonisolated static func apply(_ input: CIImage, filter: ImageProFilter) -> CIImage {
        let name: String
        switch filter.kind {
        case .gaussianBlur: name = "CIGaussianBlur"
        case .boxBlur: name = "CIBoxBlur"
        case .motionBlur: name = "CIMotionBlur"
        case .zoomBlur: name = "CIZoomBlur"
        case .pixelate: name = "CIPixellate"
        case .crystallize: name = "CICrystallize"
        case .emboss: name = "CIConvolutionRGB3X3"
        case .edgeWork: name = "CIEdgeWork"
        case .twirl: name = "CITwirlDistortion"
        case .bump: name = "CIBumpDistortion"
        case .glassLoops: name = "CIGlassLoops"
        case .unsharpMask: name = "CIUnsharpMask"
        case .highPass: name = "CIHighPassFilter"
        }
        guard let f = CIFilter(name: name) else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        switch filter.kind {
        case .gaussianBlur, .boxBlur, .unsharpMask, .highPass:
            f.setValue(filter.radius, forKey: kCIInputRadiusKey)
        case .motionBlur, .zoomBlur, .glassLoops:
            f.setValue(filter.radius, forKey: kCIInputRadiusKey)
            f.setValue(filter.angle, forKey: kCIInputAngleKey)
        case .pixelate, .crystallize:
            f.setValue(filter.radius, forKey: "inputScale")
        case .emboss:
            f.setValue(filter.radius, forKey: "inputWeight")
        case .edgeWork:
            f.setValue(filter.radius, forKey: kCIInputRadiusKey)
        case .twirl, .bump:
            f.setValue(filter.radius, forKey: kCIInputRadiusKey)
        }
        return f.outputImage ?? input
    }

    var localizedTitle: String { kind.localizedTitle }
}
