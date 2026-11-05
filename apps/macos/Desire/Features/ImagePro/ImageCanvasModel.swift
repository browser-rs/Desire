import Combine
import CoreGraphics
import Foundation

/// 画布视图状态（v0.8.46 画布重写）：只持有**视口**（zoom/pan/容器），
/// 不掺编辑数据。编辑数据（base 像素、管线、图层）仍归 ImageEditorDocument /
/// ImageEditorView；坐标换算全走 `transform`。
@MainActor
final class ImageCanvasModel: ObservableObject {
    /// 当前缩放（1 = 100% 显示像素）。
    @Published var zoom: CGFloat = 1
    /// 相对"居中原点"的平移（画布点）。
    @Published var pan: CGSize = .zero
    /// 是否处于"适应窗口"模式（窗口尺寸变化时自动重算）。
    @Published var isFitMode = true
    /// 当前内容下的适应比例。
    @Published var fitZoom: CGFloat = 1
    /// 画布容器尺寸（事件层 bounds）。
    @Published var containerSize: CGSize = .zero

    /// 内容像素尺寸（显示图，未乘 zoom）——由视图每次 body 传入。
    var displaySize = CGSize(width: 1, height: 1)
    /// 底图像素尺寸。
    var baseSize = CGSize(width: 1, height: 1)
    /// 管线几何 ops（正向顺序）。
    var geometryOps: [ImageEditOperation.GeometryAction] = []

    var transform: ImageCanvasTransform {
        ImageCanvasTransform(containerSize: containerSize,
                             displaySize: displaySize,
                             baseSize: baseSize,
                             geometryOps: geometryOps,
                             zoom: zoom,
                             pan: pan)
    }

    func updateContent(display: CGSize, base: CGSize,
                       ops: [ImageEditOperation.GeometryAction]) {
        let changed = display != displaySize || base != baseSize
        displaySize = display
        baseSize = base
        geometryOps = ops
        guard changed else { return }
        recomputeFit()
    }

    /// 适应窗口（四周留 20pt）。
    func recomputeFit() {
        guard containerSize.width > 40, containerSize.height > 40 else { return }
        fitZoom = ImageCanvasTransform.fitZoom(container: containerSize,
                                               display: displaySize)
        if isFitMode {
            zoom = fitZoom
            pan = .zero
        }
    }

    /// 锚点缩放（滚轮/捏合/双击共用）。
    func zoom(to target: CGFloat, anchor: CGPoint) {
        let t = transform
        let result = t.zoomed(to: target, anchor: anchor)
        zoom = result.zoom
        pan = result.pan
        // 手动缩放一律退出"适应窗口"：此前用 |zoom-fitZoom| 判定，若命令在
        // 布局完成前到达（fitZoom 还是默认 1），会误判为 fit，随后布局重算
        // fit 把用户的 100% 拽回 45%（实测）。
        isFitMode = false
    }

    func zoom(by factor: CGFloat, anchor: CGPoint) {
        zoom(to: transform.zoom * factor, anchor: anchor)
    }

    /// 100%（1 显示像素 = 1 画布点）。
    func actualSize(anchor: CGPoint) {
        zoom(to: 1, anchor: anchor)
    }

    func fit(anchor: CGPoint? = nil) {
        isFitMode = true
        zoom = fitZoom
        pan = .zero
        _ = anchor
    }

    /// 以容器中心为锚的按钮缩放。
    func zoomFromCenter(by factor: CGFloat) {
        let anchor = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        isFitMode = false
        zoom(by: factor, anchor: anchor)
    }
}
