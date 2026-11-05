import Combine
import AppKit
import CoreGraphics
import Foundation

/// 图层运行时（迭代 2 · v0.8.42）：账本（账本与顺序来自 `ImageLayerCore`）+
/// 每图层位图。背景层位图 = 编辑器烙图后的基础图；叠加层初始透明。
/// 保存/导出 = 按渲染顺序烙图（blend mode + opacity），导出后账本不变
/// （非破坏：图层保持，继续编辑）。
@MainActor
final class ImageLayerStore: ObservableObject {
    static let shared = ImageLayerStore()

    @Published private(set) var stack: [ImageLayer] = [ImageLayer(name: "Background")]
    @Published private(set) var bitmaps: [UUID: CGImage] = [:]

    private init() {}

    func reset(base: CGImage) {
        if let first = stack.first {
            bitmaps[first.id] = base
        } else {
            stack = [ImageLayer(name: "Background")]
            bitmaps = [stack[0].id: base]
        }
        // 叠加层位图清掉（文档切换语义）
        for layer in stack.dropFirst() where bitmaps[layer.id] == nil {
            bitmaps[layer.id] = nil
        }
        objectWillChange.send()
    }

    var canAdd: Bool { stack.count < ImageLayerCore.maxLayers }

    /// 新增空白透明图层（名为自动生成）。
    @discardableResult
    func addLayer(name: String? = nil) -> ImageLayer? {
        guard canAdd else { return nil }
        let name = name ?? ImageLayerCore.fallbackName(for: stack)
        guard let next = ImageLayerCore.adding(stack, name: name) else { return nil }
        stack = next
        if let layer = stack.last {
            bitmaps[layer.id] = Self.transparentImage(width: 1, height: 1)
        }
        objectWillChange.send()
        return stack.last
    }

    /// 置入图像为新图层（粘贴/文件）。
    @discardableResult
    func addImageLayer(_ image: CGImage, name: String) -> ImageLayer? {
        guard canAdd else { return nil }
        let name = ImageLayerCore.fallbackName(for: stack)
        guard let next = ImageLayerCore.adding(stack, name: name) else { return nil }
        stack = next
        if let layer = stack.last {
            bitmaps[layer.id] = image
        }
        objectWillChange.send()
        return stack.last
    }

    func remove(_ id: UUID) {
        guard stack.count > 1, stack.first?.id != id,
              stack.contains(where: { $0.id == id }) else { return }
        stack.removeAll { $0.id == id }
        bitmaps[id] = nil
        objectWillChange.send()
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        stack[index].isVisible = visible
        objectWillChange.send()
    }

    func setOpacity(_ id: UUID, _ opacity: Double) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        stack[index].opacity = opacity.clamped(0, 1)
        objectWillChange.send()
    }

    func setBlendMode(_ id: UUID, _ mode: ImageLayerBlendMode) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        stack[index].blendMode = mode
        objectWillChange.send()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = stack.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        stack[index].name = name.trimmingCharacters(in: .whitespaces)
        objectWillChange.send()
    }

    /// 把 id 图层上移/下移一位（0 = 背景；背景不可动）。
    func move(_ id: UUID, up: Bool) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard index > 0, stack.indices.contains(target) else { return }
        stack = ImageLayerCore.moving(stack, from: index, to: target)
        objectWillChange.send()
    }

    func bitmap(for id: UUID) -> CGImage? { bitmaps[id] }

    func setBitmap(_ image: CGImage, for id: UUID) {
        bitmaps[id] = image
        objectWillChange.send()
    }

    /// 当前活动绘制层（最顶可见层；标注落图默认到它）。
    var activeLayerID: UUID? {
        let order = ImageLayerCore.renderOrder(stack)
        return order.last.map { stack[$0].id }
    }

    /// 按渲染顺序烙图全部可见图层（blend + opacity）。
    /// 以给定 base 合成全部可见图层（编辑器画布预览用——图层此前只在
    /// 导出时合成，画布上"加了图层看不见"，v0.8.45 丰富批修复）。
    /// 单层（只有 base 层）或空栈返回 nil（调用方退回原显示）。
    func composited(over base: CGImage) -> CGImage? {
        let order = ImageLayerCore.renderOrder(stack)
        guard stack.count > 1 else { return nil }
        var current: CGImage? = base
        for index in order {
            let layer = stack[index]
            guard let bitmap = bitmaps[layer.id] else { continue }
            if index == order.first {
                current = bitmap  // 栈底图层位图 = base 层（与 reset(base:) 同语义）
                continue
            }
            guard let existing = current else { continue }
            current = Self.composite(
                base: existing, overlay: bitmap,
                blendMode: layer.blendMode, opacity: layer.opacity)
                ?? existing
        }
        return current
    }

    func flattened() -> CGImage? {
        let order = ImageLayerCore.renderOrder(stack)
        var current: CGImage?
        for index in order {
            let layer = stack[index]
            guard let bitmap = bitmaps[layer.id] else { continue }
            if let existing = current {
                current = Self.composite(
                    base: existing, overlay: bitmap,
                    blendMode: layer.blendMode, opacity: layer.opacity)
                    ?? existing
            } else {
                current = bitmap
            }
        }
        return current ?? firstLayerBitmap
    }

    var firstLayerBitmap: CGImage? {
        stack.first.flatMap { bitmaps[$0.id] }
    }

    // MARK: - 合成

    nonisolated static func composite(
        base: CGImage, overlay: CGImage,
        blendMode: ImageLayerBlendMode, opacity: Double
    ) -> CGImage? {
        let width = max(base.width, overlay.width)
        let height = max(base.height, overlay.height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.setAlpha(CGFloat(opacity))
        let cgBlend: CGBlendMode
        switch blendMode {
        case .normal: cgBlend = .normal
        case .multiply: cgBlend = .multiply
        case .screen: cgBlend = .screen
        case .overlay: cgBlend = .overlay
        case .darken: cgBlend = .darken
        case .lighten: cgBlend = .lighten
        case .colorDodge: cgBlend = .colorDodge
        case .softLight: cgBlend = .softLight
        case .difference: cgBlend = .difference
        case .luminosity: cgBlend = .luminosity
        }
        context.setBlendMode(cgBlend)
        let x = CGFloat((width - overlay.width) / 2)
        let y = CGFloat((height - overlay.height) / 2)
        let drawRect = CGRect(x: x, y: y, width: CGFloat(overlay.width),
                              height: CGFloat(overlay.height))
        context.draw(overlay, in: drawRect)
        context.setBlendMode(.normal)
        context.setAlpha(1)
        return context.makeImage()
    }

    nonisolated static func transparentImage(width: Int, height: Int) -> CGImage {
        ImageLayerBitmapFactory.makeTransparent(width: max(1, width), height: max(1, height))
    }
}
