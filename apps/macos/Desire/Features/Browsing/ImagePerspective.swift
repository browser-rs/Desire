import CoreGraphics
import CoreImage
import Foundation

/// 透视校正（迭代 2 · v0.8.43）：四角归一化坐标 → CIPerspectiveCorrection。
nonisolated enum ImagePerspective {
    /// 四角顺序：左上、右上、右下、左下（归一化 0…1，y 以顶部为 0）。
    static func correct(_ image: CGImage, corners: [CGPoint]) -> CGImage? {
        guard corners.count == 4 else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // CG 坐标 y 向上：翻转归一化 y
        let tl = CIVector(x: corners[0].x * width, y: (1 - corners[0].y) * height)
        let tr = CIVector(x: corners[1].x * width, y: (1 - corners[1].y) * height)
        let br = CIVector(x: corners[2].x * width, y: (1 - corners[2].y) * height)
        let bl = CIVector(x: corners[3].x * width, y: (1 - corners[3].y) * height)
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(tl, forKey: "inputTopLeft")
        filter.setValue(tr, forKey: "inputTopRight")
        filter.setValue(br, forKey: "inputBottomRight")
        filter.setValue(bl, forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(output, from: output.extent)
    }
}
