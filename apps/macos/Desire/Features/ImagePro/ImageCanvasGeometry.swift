import CoreGraphics
import Foundation

/// 画布**唯一**坐标变换（v0.8.46 画布重写）。
///
/// 三个坐标空间，任何一处换算都必须经过这里：
/// - **canvas**：容器坐标，左上原点、y 向下（= 事件层 NSView 的 bounds）；
/// - **display**：显示图像素（可能是管线渲染结果、也可能是 >4096 的降采样图）；
/// - **base**：底图像素——编辑真正落笔的空间（几何 ops 逆映射之后）。
///
/// 约定：
/// 1. 事件进来先变 base（`basePixel(fromCanvas:)`），工具状态一律存 base；
/// 2. 覆盖层（选框/套索/预览）由 base 变回 canvas（`canvasPoint(fromBasePixel:)`）；
/// 3. 线宽/半径等视觉长度用 `baseLength(_:)`。
///
/// Foundation/CoreGraphics-only，进 tests/run.sh。
nonisolated struct ImageCanvasTransform: Equatable {
    var containerSize: CGSize
    /// 显示图像素尺寸（未乘 zoom）。
    var displaySize: CGSize
    /// 底图像素尺寸。
    var baseSize: CGSize
    /// 管线里启用的几何操作（正向顺序）。
    var geometryOps: [ImageEditOperation.GeometryAction]
    var zoom: CGFloat
    var pan: CGSize

    static let identity = ImageCanvasTransform(
        containerSize: CGSize(width: 1, height: 1),
        displaySize: CGSize(width: 1, height: 1),
        baseSize: CGSize(width: 1, height: 1),
        geometryOps: [], zoom: 1, pan: .zero)

    // MARK: - 画布几何

    /// 显示内容在屏幕上的尺寸。
    var contentSize: CGSize {
        CGSize(width: displaySize.width * zoom, height: displaySize.height * zoom)
    }

    /// 图像左上角在容器里的位置（居中 + 平移）。
    var origin: CGPoint {
        CGPoint(x: (containerSize.width - contentSize.width) / 2 + pan.width,
                y: (containerSize.height - contentSize.height) / 2 + pan.height)
    }

    /// 视觉长度换算：画布点 → base 像素（线宽、半径、字号）。
    var basePerCanvasPoint: CGFloat {
        guard contentSize.width > 0 else { return 1 }
        return baseSize.width / contentSize.width
    }

    /// 画布点长度 → base 像素长度。
    func baseLength(_ canvasLength: CGFloat) -> CGFloat {
        canvasLength * basePerCanvasPoint
    }

    // MARK: - canvas ↔ display

    func displayPixel(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }

    func canvasPoint(fromDisplayPixel point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * zoom, y: origin.y + point.y * zoom)
    }

    // MARK: - display ↔ base（几何逆映射 + 降采样归一）

    /// base 经全部几何 ops 后的尺寸（= 未降采样时的显示尺寸）。
    var geometryDisplaySize: CGSize {
        var size = baseSize
        for op in geometryOps {
            switch op {
            case .rotate90cw, .rotate90ccw:
                size = CGSize(width: size.height, height: size.width)
            case .flipH, .flipV:
                break
            }
        }
        return size
    }

    /// 显示图相对几何全尺寸的降采样比例（正常 1）。
    private var displayUpsample: CGFloat {
        guard displaySize.width > 0 else { return 1 }
        return geometryDisplaySize.width / displaySize.width
    }

    func basePixel(fromDisplayPixel point: CGPoint) -> CGPoint {
        let up = displayUpsample
        let inBaseSpace = CGPoint(x: point.x * up, y: point.y * up)
        return ImageGeometryMapper.basePoint(fromDisplay: inBaseSpace,
                                             ops: geometryOps, baseSize: baseSize)
    }

    func displayPixel(fromBasePixel point: CGPoint) -> CGPoint {
        let mapped = ImageGeometryMapper.displayPoint(fromBase: point,
                                                      ops: geometryOps,
                                                      baseSize: baseSize)
        guard geometryDisplaySize.width > 0 else { return mapped }
        let down = displaySize.width / geometryDisplaySize.width
        return CGPoint(x: mapped.x * down, y: mapped.y * down)
    }

    // MARK: - canvas ↔ base（事件/覆盖层专用）

    func basePixel(fromCanvas point: CGPoint) -> CGPoint {
        basePixel(fromDisplayPixel: displayPixel(fromCanvas: point))
    }

    func canvasPoint(fromBasePixel point: CGPoint) -> CGPoint {
        canvasPoint(fromDisplayPixel: displayPixel(fromBasePixel: point))
    }

    func canvasRect(fromBaseRect rect: CGRect) -> CGRect {
        let topLeft = canvasPoint(fromBasePixel: CGPoint(x: rect.minX, y: rect.minY))
        let bottomRight = canvasPoint(fromBasePixel: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                      width: abs(bottomRight.x - topLeft.x),
                      height: abs(bottomRight.y - topLeft.y))
    }

    func baseRect(fromCanvasRect rect: CGRect) -> CGRect {
        let topLeft = basePixel(fromCanvas: CGPoint(x: rect.minX, y: rect.minY))
        let bottomRight = basePixel(fromCanvas: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                      width: abs(bottomRight.x - topLeft.x),
                      height: abs(bottomRight.y - topLeft.y))
    }

    /// 以容器内某点为锚缩放（滚轮/捏合/双击），保持锚点下的图像不动。
    /// 返回新的 (zoom, pan)。
    func zoomed(to target: CGFloat, anchor: CGPoint,
                clamped range: ClosedRange<CGFloat> = 0.05...8) -> (zoom: CGFloat, pan: CGSize) {
        let newZoom = min(range.upperBound, max(range.lowerBound, target))
        // 锚点在 display 像素空间的位置（缩放前后不变）
        let anchorDisplay = displayPixel(fromCanvas: anchor)
        let newContent = CGSize(width: displaySize.width * newZoom,
                                height: displaySize.height * newZoom)
        // 新 origin = 锚点 - 锚点显示像素 × 新 zoom
        let baseOrigin = CGPoint(x: (containerSize.width - newContent.width) / 2,
                                 y: (containerSize.height - newContent.height) / 2)
        let newPan = CGSize(
            width: anchor.x - anchorDisplay.x * newZoom - baseOrigin.x,
            height: anchor.y - anchorDisplay.y * newZoom - baseOrigin.y)
        return (newZoom, newPan)
    }

    /// 适应窗口比例（四周留 20pt）。
    static func fitZoom(container: CGSize, display: CGSize) -> CGFloat {
        guard display.width > 0, display.height > 0 else { return 1 }
        let byWidth = (container.width - 40) / display.width
        let byHeight = (container.height - 40) / display.height
        return min(1, min(byWidth, byHeight))
    }
}
