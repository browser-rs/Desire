import CoreGraphics
import Foundation

/// 工具集（v0.8.46 重写，对齐 Photoshop 的最小可用集）。
nonisolated enum ImageEditorTool: String, CaseIterable, Sendable {
    case move
    case marquee      // 矩形/椭圆选框
    case lasso
    case wand
    case crop
    case brush
    case eraser
    case text
    case shape
    case retouch
    case gradient
    case eyedropper
    case hand
    case zoom

    var hotKey: String? {
        switch self {
        case .move: return "v"
        case .marquee: return "m"
        case .lasso: return "l"
        case .wand: return "w"
        case .crop: return "c"
        case .brush: return "b"
        case .eraser: return "e"
        case .text: return "t"
        case .shape: return "u"
        case .retouch: return "j"
        case .gradient: return "g"
        case .eyedropper: return "i"
        case .hand: return "h"
        case .zoom: return "z"
        }
    }

    var localizedTitle: String {
        switch self {
        case .move: return String(localized: "Move")
        case .marquee: return String(localized: "Marquee")
        case .lasso: return String(localized: "Lasso Tool")
        case .wand: return String(localized: "Magic Wand Tool")
        case .crop: return String(localized: "Crop")
        case .brush: return String(localized: "Brush")
        case .eraser: return String(localized: "Eraser")
        case .text: return String(localized: "Text Tool")
        case .shape: return String(localized: "Shape")
        case .retouch: return String(localized: "Retouch")
        case .gradient: return String(localized: "Gradient")
        case .eyedropper: return String(localized: "Eyedropper Tool")
        case .hand: return String(localized: "Hand")
        case .zoom: return String(localized: "Zoom")
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .crop: return "crop"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .text: return "character.textbox"
        case .shape: return "square.on.circle"
        case .retouch: return "bandage"
        case .gradient: return "circle.lefthalf.filled"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        }
    }
}

/// 形状工具的子类型。
nonisolated enum ImageEditorShape: String, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow

    var localizedTitle: String {
        switch self {
        case .rectangle: return String(localized: "Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        }
    }
}

/// 图层混合模式（CGContext 原生支持子集）。
nonisolated enum ImageEditorBlend: String, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, add

    var localizedTitle: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .multiply: return String(localized: "Multiply")
        case .screen: return String(localized: "Screen")
        case .overlay: return String(localized: "Overlay")
        case .darken: return String(localized: "Darken")
        case .lighten: return String(localized: "Lighten")
        case .add: return String(localized: "Add")
        }
    }
}

/// 图层样式（迭代 9）：投影 / 描边 / 发光，非破坏，合成时应用。
nonisolated struct ImageLayerStyle: Equatable, Sendable {
    var shadowEnabled = false
    var shadowRadius: Double = 10
    var shadowOpacity: Double = 0.6
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 6
    var shadowColor: String = "#000000"
    var strokeEnabled = false
    var strokeWidth: Double = 2
    var strokeColor: String = "#FFFFFF"
    var glowEnabled = false
    var glowRadius: Double = 14
    var glowOpacity: Double = 0.6
    var glowColor: String = "#FF4245"
    var isActive: Bool { shadowEnabled || strokeEnabled || glowEnabled }
}

/// 文字规格（可再编辑）：文字提交为自己的图层，规格存图层上，文字工具
/// 点回该层即重新打开编辑卡。颜色存 hex 字符串（CGColor 非 Sendable，
/// 模型层不能持有）；渲染时经 `textStyle()` 转换。
nonisolated struct ImageTextSpec: Equatable, Sendable {
    var text: String
    var anchorX: Double
    var anchorY: Double
    var fontName: String?
    var weight: String = "semibold"
    var fontSize: Double = 32
    var colorHex: String = "#FFFFFF"
    var alignment: String = "left"
    var lineSpacing: Double = 1.2
    var strokeWidth: Double = 0
    var strokeColorHex: String = "#000000"
    var shadow: Bool = false
    var backgroundHex: String?
    /// 渲染后的文字包围盒（图层像素；提交/重渲染时扫描一次，命中测试用，
    /// 避免每次点击全图扫描）。
    var inkBoxX: Double = 0
    var inkBoxY: Double = 0
    var inkBoxW: Double = 0
    var inkBoxH: Double = 0

    var anchor: CGPoint { CGPoint(x: anchorX, y: anchorY) }
}

/// 图层（账本；像素在 ImageEditorDocument.bitmaps）。
nonisolated struct ImageEditorLayer: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: Double = 1
    var blend: ImageEditorBlend = .normal
    /// 内容偏移（图片像素，x 右 / y 下）。移动工具只改它，位图不重采样。
    var offset: CGSize = .zero
    /// 图层变换（非破坏）：均匀缩放 + 旋转角度（度，顺时针为正）。
    var scale: Double = 1
    var rotation: Double = 0
    var isLocked: Bool = false
    var style: ImageLayerStyle?
    /// 非空 = 文字层（规格可再编辑）。位图被其它工具改写或几何带缩放/旋转
    /// 烘焙后置空（降级为普通像素层，规格无法复现视觉）。
    var textSpec: ImageTextSpec?
    /// 非破坏调整参数（合成时现算；nil/neutral = 无）。落像素工具前烘焙。
    var adjust: ImageAdjustParams?
    /// 非破坏滤镜预设（nil/.none = 无）。
    var filter: ImageFilterPreset?
}


/// 修饰模式（迭代 7）。
nonisolated enum ImageRetouchMode: String, CaseIterable, Sendable {
    case clone, heal, dodge, burn, blur, sharpen

    var localizedTitle: String {
        switch self {
        case .clone: return String(localized: "Clone Stamp")
        case .heal: return String(localized: "Heal")
        case .dodge: return String(localized: "Dodge Tool")
        case .burn: return String(localized: "Burn Tool")
        case .blur: return String(localized: "Blur Tool")
        case .sharpen: return String(localized: "Sharpen Tool")
        }
    }
}
