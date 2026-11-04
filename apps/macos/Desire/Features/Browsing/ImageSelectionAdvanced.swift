import CoreGraphics
import CoreImage
import Foundation

/// 选区高级工具（迭代 2 · v0.8.42）：套索闭合 → 归一化蒙版；魔棒 →
/// 容差 flood-fill（BFS）→ 连通/不连通两种语义。
nonisolated enum ImageSelectionAdvanced {

    /// 套索：拖拽轨迹（视图坐标）→ 多边形蒙版参数。
    /// 返回归一化顶点数组（非对称路径交给 CIBlendWithMask 的 mask 渲染）。
    static func lassoVertices(_ points: [CGPoint],
                              displaySize: CGSize) -> [CGPoint]? {
        guard points.count >= 3,
              displaySize.width > 0, displaySize.height > 0 else { return nil }
        return points.map { point in
            CGPoint(x: (point.x / displaySize.width).clamped(0, 1),
                    y: (point.y / displaySize.height).clamped(0, 1))
        }
    }

    /// 魔棒：从起点出发 BFS 相似像素（RGB 距离 ≤ tolerance），返回蒙版 CGImage。
    /// `contiguous` = 仅连通区域；false = 全图所有相似像素。
    static func magicWandMask(image: CGImage, start: CGPoint,
                              tolerance: Double, contiguous: Bool) -> CGImage? {
        let width = image.width
        let height = image.height
        let total = width * height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: total * 4)

        let sx = min(width - 1, max(0, Int(start.x)))
        let sy = min(height - 1, max(0, Int(start.y)))
        let startOffset = (sy * width + sx) * 4
        let seedR = Double(buffer[startOffset])
        let seedG = Double(buffer[startOffset + 1])
        let seedB = Double(buffer[startOffset + 2])
        let tol = max(1, tolerance * 3)  // 0-100 → RGB 距离（欧氏约 0-173）

        func similar(_ offset: Int) -> Bool {
            let dr = Double(buffer[offset]) - seedR
            let dg = Double(buffer[offset + 1]) - seedG
            let db = Double(buffer[offset + 2]) - seedB
            return (dr * dr + dg * dg + db * db).squareRoot() <= Double(tol)
        }

        var mask = [Bool](repeating: false, count: total)
        if contiguous {
            var queue = [startOffset / 4]
            mask[startOffset / 4] = true
            var head = 0
            while head < queue.count {
                let pixelIndex = queue[head]
                head += 1
                let px = pixelIndex % width
                let py = pixelIndex / width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx
                    let ny = py + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighborIndex = ny * width + nx
                    if mask[neighborIndex] { continue }
                    let neighborOffset = neighborIndex * 4
                    if similar(neighborOffset) {
                        mask[neighborIndex] = true
                        queue.append(neighborIndex)
                    }
                }
            }
        } else {
            for index in 0..<total where similar(index * 4) {
                mask[index] = true
            }
        }

        // mask → CGImage（灰度：白 = 选中）
        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let maskBuffer = maskContext.data!.bindMemory(to: UInt8.self,
                                                      capacity: total)
        for index in 0..<total {
            maskBuffer[index] = mask[index] ? 255 : 0
        }
        return maskContext.makeImage()
    }
}
