import CoreGraphics
import Foundation

/// 像素级后验（v0.8.56 批 1 完善）：clickAt 的主场景是 canvas/自绘 UI——
/// 点击后 DOM 指纹（innerText/节点数）纹丝不动，`[verify] page unchanged`
/// 会误导模型弃用刚生效的操作。像素对比兜底：点击前后各抓一张 160px 宽
/// 灰度缩略图，统计显著变化的像素占比。
/// Foundation/CoreGraphics、进 tests/run.sh。
nonisolated enum PixelDiff {

    /// 判定"变了"的差异占比阈值（0.02 = 2% 像素灰阶差 >12）。
    static let changedThreshold = 0.02
    /// 单通道显著变化阈值（JPEG 噪声/抗锯齿抖动在此之下）。
    static let significance = 12

    /// 两张**同尺寸**灰度图中显著变化的像素占比；长度不符返回 0（调用方
    /// 视为不可判）。任一为空也返回 0。
    static func changedRatio(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > significance {
            changed += 1
        }
        return Double(changed) / Double(a.count)
    }

    /// 灰度缩略图字节（宽 `width`，高按纵横比；绘制失败返回 nil）。
    static func grayscale(_ image: CGImage, width: Int = 160) -> [UInt8]? {
        let w = max(1, width)
        let h = max(1, Int((Double(image.height) / Double(image.width) * Double(w)).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
