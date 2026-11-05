import CoreGraphics
import Foundation

/// 选区（v0.8.46 重写）：统一 base 像素坐标（左上原点、y 向下）。
/// 三种来源：矩形/椭圆选框、套索多边形、魔棒蒙版；可羽化/反选。
nonisolated struct ImageEditorSelection {
    /// 矩形/椭圆选区（base 像素）。
    var rect: CGRect?
    var isEllipse: Bool = false
    /// 自定义灰度蒙版（白 = 选中；与 rect 互斥）。
    var mask: CGImage?
    /// 羽化（0…0.5，相对短边）。
    var feather: Double = 0
    /// 反选。
    var inverted: Bool = false
    /// 全选。
    var selectAll: Bool = false

    var isEmpty: Bool {
        rect == nil && mask == nil && !selectAll
    }

    var describe: String {
        if selectAll { return "All" }
        if let rect {
            return "\(Int(rect.width)) × \(Int(rect.height)) @ \(Int(rect.minX)),\(Int(rect.minY))"
        }
        if mask != nil { return "Mask" }
        return "None"
    }

    /// 选区在 base 像素里的包围盒（绘制蚂蚁线用）。
    func bounds(canvasSize: CGSize) -> CGRect? {
        if selectAll { return CGRect(origin: .zero, size: canvasSize) }
        if let rect { return rect }
        if let mask { return ImageEditorRaster.maskBounds(mask) }
        return nil
    }

    /// 生成灰度蒙版（无选区返回 nil = 全图）。
    func maskImage(canvasSize: CGSize) -> CGImage? {
        guard !isEmpty else { return nil }
        return ImageEditorRaster.selectionMask(self, size: canvasSize)
    }
}
