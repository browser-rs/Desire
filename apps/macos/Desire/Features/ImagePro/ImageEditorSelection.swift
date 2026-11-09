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

    /// mask 包围盒缓存：maskBounds 要把 96MB 蒙版整幅提取+逐像素扫描
    ///（96MP 实测 ~500ms），而 selectionOverlay 每帧都调 bounds()。
    /// key = 蒙版对象身份（选区变化 = 新 CGImage，缓存自动失效）。
    private var maskBoundsCache: (mask: CGImage, box: CGRect?)?

    /// 选区在 base 像素里的包围盒（绘制蚂蚁线/调试探针用）。
    mutating func bounds(canvasSize: CGSize) -> CGRect? {
        if selectAll { return CGRect(origin: .zero, size: canvasSize) }
        if let rect { return rect }
        if let mask {
            if let cache = maskBoundsCache, cache.mask === mask {
                return cache.box
            }
            let box = ImageEditorRaster.maskBounds(mask)
            maskBoundsCache = (mask, box)
            return box
        }
        return nil
    }

    /// 生成灰度蒙版（无选区返回 nil = 全图）。
    func maskImage(canvasSize: CGSize) -> CGImage? {
        guard !isEmpty else { return nil }
        return ImageEditorRaster.selectionMask(self, size: canvasSize)
    }
}
