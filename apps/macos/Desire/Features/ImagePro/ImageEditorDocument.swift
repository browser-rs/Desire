import Combine
import CoreGraphics
import Foundation

/// 图片文档（v0.8.46 画布重写）：图层账本 + 位图 + 选区 + 历史。
/// 所有像素坐标 = **base 像素（左上原点、y 向下）**。
/// 视图层只调这里的方法，不再自己碰 CGContext / 坐标换算。
@MainActor
final class ImageEditorDocument: ObservableObject {

    // MARK: - 状态

    @Published private(set) var layers: [ImageEditorLayer] = []
    @Published private(set) var activeLayerID: UUID
    @Published private(set) var revision = 0
    @Published private(set) var historyTitles: [String] = []
    @Published private(set) var redoCount = 0
    @Published private(set) var selection = ImageEditorSelection()
    @Published private(set) var canvasSize = CGSize(width: 1, height: 1)
    @Published private(set) var isDirty = false

    private var bitmaps: [UUID: CGImage] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var compositeCache: (revision: Int, image: CGImage?)?
    private let maxHistory = 40

    private struct Snapshot {
        var title: String
        var layers: [ImageEditorLayer]
        var bitmaps: [UUID: CGImage]
        var activeLayerID: UUID
        var selection: ImageEditorSelection
        var canvasSize: CGSize
    }

    // MARK: - 初始化

    init(image: CGImage, name: String) {
        canvasSize = CGSize(width: image.width, height: image.height)
        let base = ImageEditorLayer(id: UUID(), name: name.isEmpty ? "Background" : name)
        layers = [base]
        activeLayerID = base.id
        bitmaps = [base.id: image]
    }

    // MARK: - 查询

    var activeLayer: ImageEditorLayer? {
        layers.first { $0.id == activeLayerID }
    }

    var activeBitmap: CGImage? {
        bitmaps[activeLayerID]
    }

    /// 当前图层内容偏移（文档像素）。
    var activeLayerOffset: CGSize {
        activeLayer?.offset ?? .zero
    }

    func bitmap(for id: UUID) -> CGImage? { bitmaps[id] }

    /// 合成结果（按图层顺序自下而上，含可见性/透明度/混合）。
    func composite() -> CGImage? {
        if let cache = compositeCache, cache.revision == revision, let image = cache.image {
            return image
        }
        let image = ImageEditorRaster.composite(layers: layers, bitmaps: bitmaps,
                                                size: canvasSize)
        compositeCache = (revision, image)
        return image
    }

    /// 导出/保存用：合成后铺白底（可选）。
    func flattened(over backdrop: CGColor?) -> CGImage? {
        guard let composite = composite() else { return nil }
        return ImageEditorRaster.flattened(composite, over: backdrop)
    }

    // MARK: - 历史

    private func pushHistory(_ title: String) {
        undoStack.append(Snapshot(title: title, layers: layers, bitmaps: bitmaps,
                                  activeLayerID: activeLayerID,
                                  selection: selection, canvasSize: canvasSize))
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        historyTitles = undoStack.map(\.title)
        redoCount = 0
    }

    private func commit() {
        revision += 1
        isDirty = true
        historyTitles = undoStack.map(\.title)
        redoCount = redoStack.count
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(title: snapshot.title, layers: layers, bitmaps: bitmaps,
                                  activeLayerID: activeLayerID,
                                  selection: selection, canvasSize: canvasSize))
        restore(snapshot)
        revision += 1
        historyTitles = undoStack.map(\.title)
        redoCount = redoStack.count
        isDirty = true
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(title: snapshot.title, layers: layers, bitmaps: bitmaps,
                                  activeLayerID: activeLayerID,
                                  selection: selection, canvasSize: canvasSize))
        restore(snapshot)
        revision += 1
        historyTitles = undoStack.map(\.title)
        redoCount = redoStack.count
        isDirty = true
    }

    /// 历史面板：回退到指定深度（0 = Original）。
    func undo(toDepth depth: Int) {
        let target = max(0, min(depth, undoStack.count))
        while undoStack.count > target { undo() }
    }

    private func restore(_ snapshot: Snapshot) {
        layers = snapshot.layers
        bitmaps = snapshot.bitmaps
        activeLayerID = snapshot.activeLayerID
        selection = snapshot.selection
        canvasSize = snapshot.canvasSize
        compositeCache = nil
    }

    func markSaved() {
        isDirty = false
    }

    // MARK: - 图层

    @discardableResult
    func addLayer(name: String? = nil, bitmap: CGImage? = nil) -> UUID? {
        pushHistory("New Layer")
        let layer = ImageEditorLayer(id: UUID(),
                                     name: name ?? "Layer \(layers.count)")
        let index = layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: index)
        bitmaps[layer.id] = bitmap ?? ImageEditorRaster.transparent(size: canvasSize)
        activeLayerID = layer.id
        compositeCache = nil
        commit()
        return layer.id
    }

    func duplicateActiveLayer() {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }),
              let bitmap = bitmaps[activeLayerID] else { return }
        pushHistory("Duplicate Layer")
        var copy = layers[index]
        copy.id = UUID()
        copy.name += " copy"
        layers.insert(copy, at: index + 1)
        bitmaps[copy.id] = bitmap
        activeLayerID = copy.id
        compositeCache = nil
        commit()
    }

    func deleteActiveLayer() {
        guard layers.count > 1,
              let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        pushHistory("Delete Layer")
        let removed = layers.remove(at: index)
        bitmaps[removed.id] = nil
        let next = min(index, layers.count - 1)
        activeLayerID = layers[max(0, next)].id
        compositeCache = nil
        commit()
    }

    func moveActiveLayer(up: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        let target = up ? index + 1 : index - 1
        guard layers.indices.contains(target) else { return }
        pushHistory(up ? "Raise Layer" : "Lower Layer")
        layers.swapAt(index, target)
        compositeCache = nil
        commit()
    }

    func selectLayer(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        activeLayerID = id
    }

    func setLayerVisible(_ id: UUID, visible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        pushHistory(visible ? "Show Layer" : "Hide Layer")
        layers[index].isVisible = visible
        compositeCache = nil
        commit()
    }

    func setLayerOpacity(_ id: UUID, opacity: Double) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(1, max(0, opacity))
        compositeCache = nil
        commit()
    }

    func setLayerBlend(_ id: UUID, blend: ImageEditorBlend) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        pushHistory("Blend Layer")
        layers[index].blend = blend
        compositeCache = nil
        commit()
    }

    func renameLayer(_ id: UUID, name: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].name = name
        commit()
    }

    // MARK: - 位图编辑

    /// 用新位图替换指定图层（一次历史）。
    func replaceBitmap(_ id: UUID, with image: CGImage, title: String) {
        guard bitmaps[id] != nil else { return }
        pushHistory(title)
        bitmaps[id] = image
        compositeCache = nil
        commit()
    }

    func replaceActiveBitmap(_ image: CGImage, title: String) {
        replaceBitmap(activeLayerID, with: image, title: title)
    }

    /// 直接改位图但不进历史（画笔拖动中的中间帧；调用方在起始处 push 一次）。
    func setBitmapLive(_ id: UUID, _ image: CGImage) {
        guard bitmaps[id] != nil else { return }
        bitmaps[id] = image
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    /// 为"一次拖动 = 一步历史"准备：拖拽开始前调一次。
    func beginContinuousEdit(_ title: String) {
        pushHistory(title)
    }

    /// 平移当前图层内容（move 工具）。
    /// 移动工具：只改图层偏移（不重采样、不裁内容），取整像素。
    func setLayerOffset(_ id: UUID, _ offset: CGSize) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let rounded = CGSize(width: offset.width.rounded(), height: offset.height.rounded())
        guard layers[index].offset != rounded else { return }
        layers[index].offset = rounded
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    /// 命令 API：相对移动当前图层（一步历史）。
    func nudgeActiveLayer(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0,
              let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        pushHistory("Move")
        layers[index].offset = CGSize(width: (layers[index].offset.width + dx).rounded(),
                                      height: (layers[index].offset.height + dy).rounded())
        compositeCache = nil
        commit()
    }

    /// 结构性操作（裁剪/缩放/旋转/翻转）前把偏移烘进像素：这些操作会改画布，
    /// 必须让"文档空间 == 位图空间"。
    private func bakeOffsets() {
        for index in layers.indices where layers[index].offset != .zero {
            let id = layers[index].id
            guard let bitmap = bitmaps[id],
                  let ctx = CGContext(data: nil,
                                      width: Int(canvasSize.width), height: Int(canvasSize.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            let offset = layers[index].offset
            ctx.draw(bitmap, in: CGRect(x: offset.width, y: -offset.height,
                                        width: CGFloat(bitmap.width),
                                        height: CGFloat(bitmap.height)))
            bitmaps[id] = ctx.makeImage()
            layers[index].offset = .zero
        }
        compositeCache = nil
    }

    /// 拖动中的平移（不进历史；起始处 beginContinuousEdit 一次）。
    func translateActiveLayerLive(dx: CGFloat, dy: CGFloat) {
        guard let bitmap = bitmaps[activeLayerID],
              let ctx = CGContext(data: nil, width: bitmap.width, height: bitmap.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(bitmap, in: CGRect(x: dx, y: -dy, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
        guard let out = ctx.makeImage() else { return }
        setBitmapLive(activeLayerID, out)
    }

    func translateActiveLayer(dx: CGFloat, dy: CGFloat, title: String = "Move") {
        guard let bitmap = bitmaps[activeLayerID],
              let ctx = CGContext(data: nil, width: bitmap.width, height: bitmap.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(bitmap, in: CGRect(x: dx, y: -dy, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
        guard let out = ctx.makeImage() else { return }
        replaceActiveBitmap(out, title: title)
    }

    // MARK: - 选区

    func setSelectionRect(_ rect: CGRect, ellipse: Bool, feather: Double) {
        var sel = ImageEditorSelection()
        let clamped = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        sel.rect = clamped.width >= 1 && clamped.height >= 1 ? clamped : nil
        sel.isEllipse = ellipse
        sel.feather = feather
        selection = sel
    }

    func setSelectionMask(_ mask: CGImage?, feather: Double) {
        var sel = ImageEditorSelection()
        sel.mask = mask
        sel.feather = feather
        selection = sel
    }

    func selectAll() {
        var sel = ImageEditorSelection()
        sel.selectAll = true
        selection = sel
    }

    func clearSelection() {
        selection = ImageEditorSelection()
    }

    func invertSelection() {
        var sel = selection
        if sel.isEmpty {
            // 无选区反选 = 全选
            selectAll()
            return
        }
        sel.inverted.toggle()
        selection = sel
    }

    // MARK: - 效果

    /// 位图空间的选区蒙版（图层有偏移时平移）。
    private func bitmapMask() -> CGImage? {
        guard let mask = selection.maskImage(canvasSize: canvasSize) else { return nil }
        let offset = activeLayerOffset
        guard offset != .zero else { return mask }
        return ImageEditorRaster.shiftedMask(mask, dx: -offset.width, dy: -offset.height) ?? mask
    }

    func applyAdjust(_ params: ImageAdjustParams, title: String = "Adjust") {
        guard let current = bitmaps[activeLayerID] else { return }
        let mask = bitmapMask()
        guard let output = ImageEditorRaster.applyEffect(current, adjust: params,
                                                         filter: nil, mask: mask)
        else { return }
        replaceActiveBitmap(output, title: title)
    }

    func applyFilter(_ preset: ImageFilterPreset, title: String = "Filter") {
        guard let current = bitmaps[activeLayerID] else { return }
        let mask = bitmapMask()
        guard let output = ImageEditorRaster.applyEffect(current, adjust: nil,
                                                         filter: preset, mask: mask)
        else { return }
        replaceActiveBitmap(output, title: title)
    }

    // MARK: - 几何

    func crop(to rect: CGRect) {
        let clamped = rect.intersection(CGRect(origin: .zero, size: canvasSize)).integral
        guard clamped.width >= 1, clamped.height >= 1,
              clamped.size != canvasSize else { return }
        pushHistory("Crop")
        bakeOffsets()
        for (id, bitmap) in bitmaps {
            bitmaps[id] = ImageTransforms.cropped(bitmap, rect: clamped) ?? bitmap
        }
        canvasSize = clamped.size
        selection = ImageEditorSelection()
        compositeCache = nil
        commit()
    }

    func resize(to size: CGSize) {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        guard w != Int(canvasSize.width) || h != Int(canvasSize.height) else { return }
        pushHistory("Resize")
        bakeOffsets()
        for (id, bitmap) in bitmaps {
            bitmaps[id] = ImageTransforms.resized(bitmap, width: w, height: h) ?? bitmap
        }
        canvasSize = CGSize(width: w, height: h)
        selection = ImageEditorSelection()
        compositeCache = nil
        commit()
    }

    func rotate(clockwise: Bool) {
        pushHistory(clockwise ? "Rotate Right" : "Rotate Left")
        bakeOffsets()
        for (id, bitmap) in bitmaps {
            bitmaps[id] = ImageTransforms.rotated(bitmap, clockwise: clockwise) ?? bitmap
        }
        canvasSize = CGSize(width: canvasSize.height, height: canvasSize.width)
        selection = ImageEditorSelection()
        compositeCache = nil
        commit()
    }

    func flip(horizontal: Bool) {
        pushHistory(horizontal ? "Flip Horizontal" : "Flip Vertical")
        bakeOffsets()
        for (id, bitmap) in bitmaps {
            bitmaps[id] = ImageTransforms.flipped(bitmap, horizontal: horizontal) ?? bitmap
        }
        selection = ImageEditorSelection()
        compositeCache = nil
        commit()
    }

    // MARK: - 采样

    func sampleColor(at point: CGPoint) -> CGColor? {
        guard let composite = composite() else { return nil }
        return ImageEditorRaster.sampleColor(composite, at: point)
    }
}
