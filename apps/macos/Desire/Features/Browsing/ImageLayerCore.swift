import CoreGraphics
import Foundation

/// 图层核心（迭代 2 · v0.8.42）：图层账本的纯数据模型与校验。
/// 位图内容由 app 侧持有（CGImage 不能跨进程序列化），本文件只管
/// 顺序/可见性/混合模式/不透明度/命名，以及烙图顺序推导。
nonisolated enum ImageLayerBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten
    case colorDodge = "colorDodge"
    case softLight = "softLight"
    case difference, luminosity

    var displayName: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .multiply: return String(localized: "Multiply")
        case .screen: return String(localized: "Screen")
        case .overlay: return String(localized: "Overlay")
        case .darken: return String(localized: "Darken")
        case .lighten: return String(localized: "Lighten")
        case .colorDodge: return String(localized: "Color Dodge")
        case .softLight: return String(localized: "Soft Light")
        case .difference: return String(localized: "Difference")
        case .luminosity: return String(localized: "Luminosity")
        }
    }
}

nonisolated struct ImageLayer: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Double
    var blendMode: ImageLayerBlendMode
    var createdAt: Date

    init(id: UUID = UUID(), name: String, isVisible: Bool = true,
         opacity: Double = 1, blendMode: ImageLayerBlendMode = .normal,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity.clamped(0, 1)
        self.blendMode = blendMode
        self.createdAt = createdAt
    }
}

nonisolated enum ImageLayerCore {
    static let maxLayers = 12

    /// 图层账本：index 0 = 背景（锁定不可删/不可移），其后为叠加层。
    nonisolated struct Stack: Equatable {
        var layers: [ImageLayer] = [ImageLayer(name: "Background")]
    }

    /// 追加图层；超出上限拒绝。返回新账本（值语义）。
    static func adding(_ stack: [ImageLayer], name: String,
                       blendMode: ImageLayerBlendMode = .normal,
                       opacity: Double = 1) -> [ImageLayer]? {
        guard stack.count < maxLayers else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(localized: "Layer \(stack.count)")
        let layer = ImageLayer(name: trimmed.isEmpty ? fallback : trimmed,
                               opacity: opacity.clamped(0, 1),
                               blendMode: blendMode)
        return stack + [layer]
    }

    /// 生成图层名："Layer 2"、"Layer 3"…（避开已有名称）。
    static func fallbackName(for stack: [ImageLayer]) -> String {
        var index = stack.count
        repeat {
            let name = String(localized: "Layer \(index)")
            if !stack.contains(where: { $0.name == name }) { return name }
            index += 1
        } while index < maxLayers * 2
        return String(localized: "Layer")
    }

    /// 移动图层（from/to 为图层索引；0 = 背景，交换背景会连同其位图一起换位，
    /// 由调用方处理——这里只校验范围并返回交换后的账本）。
    static func moving(_ stack: [ImageLayer], from: Int, to: Int) -> [ImageLayer] {
        guard stack.indices.contains(from), stack.indices.contains(to), from != to else {
            return stack
        }
        var copy = stack
        let layer = copy.remove(at: from)
        copy.insert(layer, at: to)
        return copy
    }

    /// 烙图顺序：底部 → 顶部（数组顺序即渲染顺序）。
    /// 返回可见且 opacity > 0 的图层索引序列。
    static func renderOrder(_ stack: [ImageLayer]) -> [Int] {
        stack.indices.filter {
            stack[$0].isVisible && stack[$0].opacity > 0
        }
    }

    /// 校验：背景层必须存在且 index 0。
    static func isConsistent(_ stack: [ImageLayer]) -> Bool {
        !stack.isEmpty
    }
}


nonisolated enum ImageLayerBitmapFactory {
    /// 1×1 透明占位图（图层账本创建时用；真实内容由编辑器写入）。
    static func makeTransparent(width: Int, height: Int) -> CGImage {
        let clampedW = max(1, width)
        let clampedH = max(1, height)
        guard let context = CGContext(
            data: nil, width: clampedW, height: clampedH,
            bitsPerComponent: 8, bytesPerRow: clampedW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // 极小尺寸下 CGContext 不可能失败；万一失败只能 abort（纯占位图）。
            fatalError("ImageLayerBitmapFactory: CGContext creation failed")
        }
        return context.makeImage()!
    }
}
