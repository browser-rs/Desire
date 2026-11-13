import AppKit

/// 液化变形画笔（v0.8.54 批 7）：对内容位图做**向前推挤**位移——沿拖拽
/// delta 把圆盘内像素软边推移（Photoshop Forward Warp 的笔刷版）。
/// 同时提供膨胀/收缩（径向位移）。全部走 CPU buffer + 软边蒙版混回，
/// 位移量随 delta 长度限制（防拉花），逐点调用（与 brush 逐点同构）。
@MainActor
enum LiquifyBrush {

    enum Mode {
        /// 向前推挤：像素沿拖拽方向位移
        case push
        /// 膨胀：像素向圆心外推
        case expand
        /// 收缩：像素向圆心聚拢
        case pinch
    }

    /// 在 `base` 上以 `center` 为圆心应用位移（文档像素坐标，y 向下）。
    /// - push: `delta` = 本段拖拽位移
    /// - expand/pinch: `delta` 的 dx 忽略，dy 的长度用作强度倍率（默认 1）
    static func warp(_ base: CGImage, center: CGPoint, radius: CGFloat,
                     mode: Mode, delta: CGPoint) -> CGImage? {
        let w = base.width, h = base.height
        guard let inData = base.dataProvider?.data,
              let inPtr = CFDataGetBytePtr(inData) else { return nil }
        let bytesPerRow = 4 * w
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * h)
        defer { outBuf.deallocate() }
        // 拷贝原图（未受位移影响的像素保持原样）
        memcpy(outBuf, inPtr, bytesPerRow * h)

        // 位移向量
        let dx: Double
        let dy: Double
        switch mode {
        case .push:
            dx = Double(delta.x)
            dy = Double(delta.y)
        case .expand, .pinch:
            dx = 0
            dy = 0
        }

        let r = Int(radius.rounded())
        let cx = Int(center.x.rounded())
        let cy = Int(center.y.rounded())
        let maxShift = radius * 0.45 // 位移上限，防拉裂

        for py in max(0, cy - r)...min(h - 1, cy + r) {
            for px in max(0, cx - r)...min(w - 1, cx + r) {
                let ox = Double(px - cx)
                let oy = Double(py - cy)
                let dist = hypot(ox, oy)
                guard dist <= Double(radius) else { continue }
                // 软边衰减：中心 1，边缘 0
                let falloff = pow(1 - dist / Double(radius), 0.8)

                // 源采样点：当前像素按位移的**反方向**取（把源推到当前位置）
                var sx: Double
                var sy: Double
                switch mode {
                case .push:
                    sx = Double(px) - dx * falloff
                    sy = Double(py) - dy * falloff
                case .expand:
                    guard dist > 0.5 else { continue }
                    let push = falloff * Double(maxShift) * 0.35
                    let ux = ox / dist, uy = oy / dist
                    sx = Double(px) - ux * push
                    sy = Double(py) - uy * push
                case .pinch:
                    guard dist > 0.5 else { continue }
                    let pull = falloff * Double(maxShift) * 0.35
                    let ux = ox / dist, uy = oy / dist
                    sx = Double(px) + ux * pull
                    sy = Double(py) + uy * pull
                }
                sx = min(Double(w - 1), max(0, sx))
                sy = min(Double(h - 1), max(0, sy))
                let si = Int(sy.rounded()) * bytesPerRow + Int(sx.rounded()) * 4
                let di = py * bytesPerRow + px * 4
                outBuf[di + 0] = inPtr[si + 0]
                outBuf[di + 1] = inPtr[si + 1]
                outBuf[di + 2] = inPtr[si + 2]
                outBuf[di + 3] = inPtr[si + 3]
            }
        }

        // 供 CGImage 构造的独立 release（outBuf 的生命周期由 provider 接管）
        let provider = CGDataProvider(dataInfo: nil, data: outBuf,
                                      size: bytesPerRow * h,
                                      releaseData: { _, pointer, _ in
                                          pointer.deallocate()
                                      })
        guard let provider, let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else {
            outBuf.deallocate()
            return nil
        }
        return cg

}
}
