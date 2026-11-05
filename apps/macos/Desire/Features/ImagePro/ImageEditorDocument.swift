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
    /// 调整/滤镜的实时预览（不落库、不进历史；保存/导出不含预览）。
    @Published private(set) var previewAdjust: ImageAdjustParams?
    @Published private(set) var previewFilter: ImageFilterPreset?

    private var bitmaps: [UUID: CGImage] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var compositeCache: (revision: Int, image: CGImage?)?
    private var thumbnailCache: [UUID: (revision: Int, image: CGImage)] = [:]
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

    /// 设置实时预览（滑杆拖动时调用）。nil/neutral = 无预览。
    func setPreview(adjust: ImageAdjustParams?, filter: ImageFilterPreset?) {
        previewAdjust = (adjust?.isNeutral == true) ? nil : adjust
        previewFilter = (filter == nil || filter == .none) ? nil : filter
        compositeCache = nil
        revision += 1
    }

    func clearPreview() {
        guard previewAdjust != nil || previewFilter != nil else { return }
        previewAdjust = nil
        previewFilter = nil
        compositeCache = nil
        revision += 1
    }

    /// 合成结果（按图层顺序自下而上，含可见性/透明度/混合）。
    func composite() -> CGImage? {
        if let cache = compositeCache, cache.revision == revision, let image = cache.image {
            return image
        }
        var effective = bitmaps
        if previewAdjust != nil || previewFilter != nil,
           let base = bitmaps[activeLayerID] {
            if let rendered = ImageEditorRaster.applyEffect(base,
                                                            adjust: previewAdjust,
                                                            filter: previewFilter,
                                                            mask: bitmapMask()) {
                effective[activeLayerID] = rendered
            }
        }
        let image = ImageEditorRaster.composite(layers: layers, bitmaps: effective,
                                                size: canvasSize)
        compositeCache = (revision, image)
        return image
    }

    /// 导出/保存用：不含实时预览（预览只是面板里的草稿）。
    func flattened(over backdrop: CGColor?) -> CGImage? {
        let savedAdjust = previewAdjust
        let savedFilter = previewFilter
        previewAdjust = nil
        previewFilter = nil
        compositeCache = nil
        let image = composite()
        previewAdjust = savedAdjust
        previewFilter = savedFilter
        compositeCache = nil
        guard let image else { return nil }
        return ImageEditorRaster.flattened(image, over: backdrop)
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

    /// 图层缩略图（按 revision 缓存，面板绘制用）。
    func thumbnail(for id: UUID, maxSide: CGFloat = 48) -> CGImage? {
        if let cached = thumbnailCache[id], cached.revision == revision {
            return cached.image
        }
        guard let bitmap = bitmaps[id] else { return nil }
        let scale = min(1, maxSide / CGFloat(max(bitmap.width, bitmap.height)))
        let w = max(1, Int(CGFloat(bitmap.width) * scale))
        let h = max(1, Int(CGFloat(bitmap.height) * scale))
        guard let small = ImageTransforms.resized(bitmap, width: w, height: h) else { return nil }
        thumbnailCache[id] = (revision, small)
        return small
    }

    /// 拖拽排序：传入"自下而上"的新顺序。
    func reorderLayers(_ newOrder: [ImageEditorLayer]) {
        guard newOrder.map(\.id) != layers.map(\.id) else { return }
        pushHistory("Reorder Layers")
        layers = newOrder
        compositeCache = nil
        commit()
    }

    /// 向下合并：当前图层按自身透明度/混合叠加到下方图层。
    func mergeDown() {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }),
              index > 0,
              let upper = bitmaps[layers[index].id],
              let lower = bitmaps[layers[index - 1].id] else { return }
        pushHistory("Merge Down")
        let size = canvasSize
        let w = Int(size.width), h = Int(size.height)
        let merged: CGImage?
        if let ctx = CGContext(data: nil, width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let lowerLayer = layers[index - 1]
            let upperLayer = layers[index]
            ctx.draw(lower, in: CGRect(x: lowerLayer.offset.width,
                                       y: -lowerLayer.offset.height,
                                       width: CGFloat(w), height: CGFloat(h)))
            ctx.saveGState()
            ctx.setAlpha(CGFloat(upperLayer.opacity))
            ctx.setBlendMode(upperLayer.blend.cgBlendMode)
            ctx.draw(upper, in: CGRect(x: upperLayer.offset.width,
                                       y: -upperLayer.offset.height,
                                       width: CGFloat(w), height: CGFloat(h)))
            ctx.restoreGState()
            merged = ctx.makeImage()
        } else {
            merged = lower
        }
        guard let merged else { return }
        layers[index - 1].offset = .zero
        bitmaps[layers[index - 1].id] = merged
        let removed = layers.remove(at: index)
        bitmaps[removed.id] = nil
        activeLayerID = layers[index - 1].id
        compositeCache = nil
        commit()
    }

    /// 拼合可见图层为单一背景层（隐藏层丢弃）。
    func flattenLayers() {
        guard layers.count > 1 else { return }
        pushHistory("Flatten")
        guard let flat = ImageEditorRaster.composite(layers: layers, bitmaps: bitmaps,
                                                     size: canvasSize) else { return }
        let background = ImageEditorLayer(id: UUID(), name: "Background")
        layers = [background]
        bitmaps = [background.id: flat]
        activeLayerID = background.id
        compositeCache = nil
        commit()
    }

    func setLayerStyle(_ id: UUID, style: ImageLayerStyle?) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].style = style
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    func setLayerLocked(_ id: UUID, locked: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isLocked = locked
        commit()
    }

    var debugCachedRevision: Int { compositeCache?.revision ?? -1 }

    var isActiveLayerLocked: Bool {
        activeLayer?.isLocked ?? false
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
        for index in layers.indices {
            let id = layers[index].id
            guard let bitmap = bitmaps[id] else { continue }
            bakeLayerGeometry(at: index, bitmap: bitmap)
        }
        compositeCache = nil
    }

    /// 把某一图层的 offset/scale/rotation 烘进画布大小的位图。
    private func bakeLayerGeometry(at index: Int, bitmap: CGImage) {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let layer = layers[index]
        let bw = CGFloat(bitmap.width), bh = CGFloat(bitmap.height)
        let center = CGPoint(x: layer.offset.width + bw / 2,
                             y: CGFloat(h) - layer.offset.height - bh / 2)
        ctx.translateBy(x: center.x, y: center.y)
        if layer.rotation != 0 { ctx.rotate(by: CGFloat(-layer.rotation * .pi / 180)) }
        if layer.scale != 1 { ctx.scaleBy(x: CGFloat(layer.scale), y: CGFloat(layer.scale)) }
        ctx.draw(bitmap, in: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh))
        bitmaps[layer.id] = ctx.makeImage()
        layers[index].offset = .zero
        layers[index].scale = 1
        layers[index].rotation = 0
    }

    /// 编辑（画笔/文字/形状）前把当前图层的几何烘平，避免坐标二次变换。
    func bakeActiveLayerGeometry() {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }),
              let bitmap = bitmaps[activeLayerID] else { return }
        let layer = layers[index]
        guard layer.offset != .zero || layer.scale != 1 || layer.rotation != 0 else { return }
        bakeLayerGeometry(at: index, bitmap: bitmap)
        compositeCache = nil
        revision += 1
    }

    // MARK: - 图层变换（非破坏）

    func setLayerScale(_ id: UUID, _ scale: Double) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].scale = min(8, max(0.05, scale))
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    func setLayerRotation(_ id: UUID, _ degrees: Double) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        layers[index].rotation = value
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    func resetLayerTransform(_ id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].scale = 1
        layers[index].rotation = 0
        compositeCache = nil
        revision += 1
        isDirty = true
    }

    /// 置入图片为图层（超画布自动等比缩放到适合，居中）。
    @discardableResult
    func placeImage(_ image: CGImage, name: String) -> UUID? {
        pushHistory("Place Image")
        var source = image
        let cw = canvasSize.width, ch = canvasSize.height
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        if iw > cw || ih > ch, let fitted = ImageTransforms.resized(
            image,
            width: max(1, Int((iw * min(cw / iw, ch / ih)).rounded())),
            height: max(1, Int((ih * min(cw / iw, ch / ih)).rounded()))) {
            source = fitted
        }
        let layer = ImageEditorLayer(id: UUID(), name: name,
                                     offset: CGSize(width: ((cw - CGFloat(source.width)) / 2).rounded(),
                                                    height: ((ch - CGFloat(source.height)) / 2).rounded()))
        let index = layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: index)
        bitmaps[layer.id] = source
        activeLayerID = layer.id
        compositeCache = nil
        commit()
        return layer.id
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

    func setSelectionRect(_ rect: CGRect, ellipse: Bool, feather: Double,
                          combine: ImageEditorRaster.SelectionCombine = .replace) {
        let clamped = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard clamped.width >= 1, clamped.height >= 1 else {
            if combine == .replace { selection = ImageEditorSelection() }
            return
        }
        var shape = ImageEditorSelection()
        shape.rect = clamped
        shape.isEllipse = ellipse
        shape.feather = feather
        if combine == .replace {
            selection = shape
            return
        }
        let existing = selection.maskImage(canvasSize: canvasSize)
        guard let shapeMask = shape.maskImage(canvasSize: canvasSize),
              let merged = ImageEditorRaster.combineMasks(existing, shapeMask,
                                                          mode: combine) else {
            if combine == .add, let shapeMask = shape.maskImage(canvasSize: canvasSize) {
                selection = ImageEditorSelection(mask: shapeMask, feather: 0)
            }
            return
        }
        selection = ImageEditorSelection(mask: merged, feather: 0)
    }

    func setSelectionMask(_ mask: CGImage?, feather: Double,
                          combine: ImageEditorRaster.SelectionCombine = .replace) {
        guard let mask else {
            if combine == .replace { selection = ImageEditorSelection() }
            return
        }
        if combine == .replace {
            var sel = ImageEditorSelection()
            sel.mask = mask
            sel.feather = feather
            selection = sel
            return
        }
        let existing = selection.maskImage(canvasSize: canvasSize)
        guard let merged = ImageEditorRaster.combineMasks(existing, mask, mode: combine) else {
            return
        }
        selection = ImageEditorSelection(mask: merged, feather: 0)
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

    /// 改画布尺寸（不缩放内容，内容按中心平移；负空间透明）。
    func resizeCanvas(to size: CGSize) {
        let w = max(1, size.width.rounded())
        let h = max(1, size.height.rounded())
        guard w != canvasSize.width || h != canvasSize.height else { return }
        pushHistory("Canvas Size")
        let dx = (w - canvasSize.width) / 2
        let dy = (h - canvasSize.height) / 2
        for index in layers.indices {
            layers[index].offset = CGSize(width: layers[index].offset.width + dx,
                                          height: layers[index].offset.height + dy)
        }
        canvasSize = CGSize(width: w, height: h)
        selection = ImageEditorSelection()
        compositeCache = nil
        commit()
    }

    /// 用空白画布重置（新建文档）。
    func reset(image: CGImage, name: String) {
        canvasSize = CGSize(width: image.width, height: image.height)
        let base = ImageEditorLayer(id: UUID(), name: name)
        layers = [base]
        bitmaps = [base.id: image]
        activeLayerID = base.id
        selection = ImageEditorSelection()
        undoStack.removeAll()
        redoStack.removeAll()
        historyTitles = []
        redoCount = 0
        previewAdjust = nil
        previewFilter = nil
        compositeCache = nil
        isDirty = false
        revision += 1
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
