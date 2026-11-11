import CoreGraphics
import Foundation

/// 图片编辑管线核心（v0.8.41 迭代 1）：非破坏、可重编辑的操作序列。
/// 纯数据 + 校验/指纹（Foundation-only，进 tests/run.sh）；CoreImage 渲染在
/// `ImagePipelineRenderer`（app 侧）。几何/标注暂时保持既有烙图语义，
/// 调节/滤镜/选区走本管线（可关闭单项、可改参重渲）。
nonisolated struct ImageAdjustParams: Codable, Hashable {
    /// -0.3…0.3
    var brightness: Double = 0
    /// 0.5…1.8（1 = 原样）
    var contrast: Double = 1
    /// 0…2
    var saturation: Double = 1
    /// 0…2（CISharpenLuminance）
    var sharpen: Double = 0
    /// -2…2 EV
    var exposure: Double = 0
    /// -100…100（正 = 偏暖）
    var temperature: Double = 0
    /// -100…100（正 = 偏绿，负 = 偏品红）
    var tint: Double = 0
    /// -1…1（正 = 提亮高光压低，负 = 压高光）
    var highlights: Double = 0
    /// -1…1（正 = 提亮阴影）
    var shadows: Double = 0
    /// -1…1
    var vibrance: Double = 0
    /// 0…1（局部对比度）
    var clarity: Double = 0
    /// 0…1
    var denoise: Double = 0
    /// 0…1
    var vignette: Double = 0
    /// 0…1（晕影羽化比例）
    var vignetteFeather: Double = 0.5
    /// 色阶黑点 0…0.4
    var blackPoint: Double = 0
    /// 色阶白点 0.6…1
    var whitePoint: Double = 1
    /// 色阶 gamma（中间调）0.2…5（1 = 原样，>1 提亮中间调）
    var gamma: Double = 1
    /// 色彩平衡 -0.3…0.3（正 = 增加该通道）
    var redBalance: Double = 0
    var greenBalance: Double = 0
    var blueBalance: Double = 0
    /// 曲线控制点（0…1，x 升序；空 = 不启用）。curvePoints = RGB 总曲线，
    /// curveRed/Green/Blue = 分通道曲线（分通道存在时优先）。
    var curvePoints: [CurvePoint] = []
    var curveRed: [CurvePoint] = []
    var curveGreen: [CurvePoint] = []
    var curveBlue: [CurvePoint] = []

    nonisolated struct CurvePoint: Codable, Hashable {
        var x: Double
        var y: Double
    }

    var hasCurve: Bool { curvePoints.count >= 2 }
    var hasChannelCurves: Bool {
        curveRed.count >= 2 || curveGreen.count >= 2 || curveBlue.count >= 2
    }
    var hasAnyCurve: Bool { hasCurve || hasChannelCurves }

    /// 全默认 = 无效果（渲染可直接跳过）。
    var isNeutral: Bool {
        self == ImageAdjustParams()
    }

    static func clamped(_ params: ImageAdjustParams) -> ImageAdjustParams {
        var p = params
        p.brightness = p.brightness.clamped(-0.3, 0.3)
        p.contrast = p.contrast.clamped(0.5, 1.8)
        p.saturation = p.saturation.clamped(0, 2)
        p.sharpen = p.sharpen.clamped(0, 2)
        p.exposure = p.exposure.clamped(-2, 2)
        p.temperature = p.temperature.clamped(-100, 100)
        p.tint = p.tint.clamped(-100, 100)
        p.highlights = p.highlights.clamped(-1, 1)
        p.shadows = p.shadows.clamped(-1, 1)
        p.vibrance = p.vibrance.clamped(-1, 1)
        p.clarity = p.clarity.clamped(0, 1)
        p.denoise = p.denoise.clamped(0, 1)
        p.vignette = p.vignette.clamped(0, 1)
        p.vignetteFeather = p.vignetteFeather.clamped(0.05, 1)
        p.blackPoint = p.blackPoint.clamped(0, 0.4)
        p.whitePoint = max(p.whitePoint.clamped(0.6, 1), p.blackPoint + 0.2)
        p.curvePoints = Self.sanitizeCurve(p.curvePoints)
        p.curveRed = Self.sanitizeCurve(p.curveRed)
        p.curveGreen = Self.sanitizeCurve(p.curveGreen)
        p.curveBlue = Self.sanitizeCurve(p.curveBlue)
        return p
    }

    /// 曲线点：x 固定升序去重，y 限制 0…1，首尾自动补 (0,0)/(1,1)。
    static func sanitizeCurve(_ points: [CurvePoint]) -> [CurvePoint] {
        let sorted = points
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(x: $0.x.clamped(0, 1), y: $0.y.clamped(0, 1)) }
            .sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for point in sorted where out.last?.x != point.x {
            out.append(point)
        }
        return out
    }

    /// 曲线在 x 处的取值（线性插值；无点 = 恒等）。
    static func curveValue(_ points: [CurvePoint], at x: Double) -> Double {
        guard points.count >= 2 else { return x }
        if x <= points[0].x {
            let first = points[0]
            return first.x <= 0 ? first.y : x
        }
        if x >= points[points.count - 1].x {
            let last = points[points.count - 1]
            return last.x >= 1 ? last.y : x
        }
        for index in 1..<points.count {
            let left = points[index - 1]
            let right = points[index]
            if x <= right.x {
                let t = (x - left.x) / max(0.000_001, right.x - left.x)
                return left.y + (right.y - left.y) * t
            }
        }
        return x
    }
}

nonisolated struct ImageSelectionParams: Codable, Hashable {
    /// 归一化 0…1（相对位图）
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// true = 椭圆选区，false = 矩形
    var ellipse: Bool
    /// 0…0.5 * min(w,h)（像素比例）
    var feather: Double

    var isNeutral: Bool { width <= 0 || height <= 0 }

    static func clamped(_ params: ImageSelectionParams) -> ImageSelectionParams {
        var p = params
        p.x = p.x.clamped(0, 1)
        p.y = p.y.clamped(0, 1)
        p.width = p.width.clamped(0, 1 - p.x)
        p.height = p.height.clamped(0, 1 - p.y)
        p.feather = p.feather.clamped(0, 0.5)
        return p
    }
}

/// 管线操作（v0.8.41 批 1：adjust / filter / selection；v0.8.43 批 1：geometry）。
nonisolated struct ImageEditOperation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case adjust, filter, selection, geometry
    }

    enum GeometryAction: String, Codable, CaseIterable {
        case rotate90cw, rotate90ccw, flipH, flipV
    }

    var id: UUID
    var kind: Kind
    var label: String
    var isEnabled: Bool
    var adjust: ImageAdjustParams?
    var filter: String?
    var selection: ImageSelectionParams?
    var geometryAction: GeometryAction?

    static func adjust(_ params: ImageAdjustParams,
                       label: String = "Adjustments") -> ImageEditOperation {
        ImageEditOperation(id: UUID(), kind: .adjust, label: label, isEnabled: true,
                           adjust: ImageAdjustParams.clamped(params))
    }

    static func filter(_ name: String) -> ImageEditOperation {
        ImageEditOperation(id: UUID(), kind: .filter, label: name, isEnabled: true,
                           filter: name)
    }

    static func selection(_ params: ImageSelectionParams) -> ImageEditOperation {
        ImageEditOperation(id: UUID(), kind: .selection, label: "Selection",
                           isEnabled: true,
                           selection: ImageSelectionParams.clamped(params))
    }

    static func geometry(_ action: GeometryAction) -> ImageEditOperation {
        ImageEditOperation(id: UUID(), kind: .geometry,
                           label: action.rawValue, isEnabled: true,
                           geometryAction: action)
    }
}

nonisolated struct ImageEditPipeline: Codable, Equatable {
    /// 上限防呆：操作数超限时拒绝追加（UI 提示）。
    static let maxOperations = 40

    var operations: [ImageEditOperation] = []

    var isEmpty: Bool { operations.isEmpty }

    mutating func append(_ operation: ImageEditOperation) -> Bool {
        guard operations.count < Self.maxOperations else { return false }
        operations.append(operation)
        return true
    }

    mutating func updateAdjust(_ id: UUID, params: ImageAdjustParams) {
        guard let index = operations.firstIndex(where: { $0.id == id && $0.kind == .adjust })
        else { return }
        operations[index].adjust = ImageAdjustParams.clamped(params)
    }

    mutating func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].isEnabled = enabled
    }

    mutating func remove(_ id: UUID) {
        operations.removeAll { $0.id == id }
    }

    /// 指纹（渲染缓存键）：操作 id/参数/开关/顺序。
    func fingerprint() -> String {
        var hasher = Hasher()
        for operation in operations {
            hasher.combine(operation.id)
            hasher.combine(operation.kind.rawValue)
            hasher.combine(operation.isEnabled)
            hasher.combine(operation.adjust)
            hasher.combine(operation.filter)
            hasher.combine(operation.selection)
        }
        let value = hasher.finalize()
        return String(format: "%016llx", UInt64(bitPattern: Int64(value)))
    }

    /// 是否需要选区蒙版（后续 selective 操作都受最后一条选区约束）。
    var activeSelection: ImageSelectionParams? {
        operations.last {
            $0.isEnabled && $0.kind == .selection
                && !($0.selection?.isNeutral ?? true)
        }?.selection
    }
}

nonisolated extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        min(max(self, lower), upper)
    }
}

nonisolated extension CGFloat {
    func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        let clampedLower = Swift.min(lower, upper)
        if self < clampedLower { return clampedLower }
        if self > upper { return upper }
        return self
    }
}

/// 几何操作的正/逆坐标映射（v0.8.45 修复）：非破坏几何（rotate/flip）后，
/// 画布显示的是管线渲染结果，而标注/裁剪/修复刷烙在 base 上——交互坐标
/// 必须从显示像素逆映射回 base 像素，否则画到画布外（"工具不生效"）。
/// 坐标系统一为左上原点、y 向下。Foundation-only，进 tests/run.sh。
nonisolated enum ImageGeometryMapper {

    /// 显示像素 → base 像素（ops 为管线顺序的正向几何序列）。
    static func basePoint(fromDisplay point: CGPoint,
                          ops: [ImageEditOperation.GeometryAction],
                          baseSize: CGSize) -> CGPoint {
        // 当前（最终）显示尺寸 = base 经全部 ops 后的尺寸
        var size = baseSize
        for op in ops {
            size = forwardSize(op, current: size)
        }
        var point = point
        for op in ops.reversed() {
            point = inversePoint(op, point, size: size)
            size = backwardSize(op, current: size)
        }
        return point
    }

    /// 显示矩形 → base 矩形（对角点映射后取包围盒；旋转后宽高互换）。
    static func baseRect(fromDisplay rect: CGRect,
                         ops: [ImageEditOperation.GeometryAction],
                         baseSize: CGSize) -> CGRect {
        let tl = basePoint(fromDisplay: CGPoint(x: rect.minX, y: rect.minY),
                           ops: ops, baseSize: baseSize)
        let br = basePoint(fromDisplay: CGPoint(x: rect.maxX, y: rect.maxY),
                           ops: ops, baseSize: baseSize)
        return CGRect(x: min(tl.x, br.x), y: min(tl.y, br.y),
                      width: abs(br.x - tl.x), height: abs(br.y - tl.y))
    }

    /// base 像素 → 显示像素（正向；调试/测试用）。
    static func displayPoint(fromBase point: CGPoint,
                             ops: [ImageEditOperation.GeometryAction],
                             baseSize: CGSize) -> CGPoint {
        var size = baseSize
        var point = point
        for op in ops {
            point = forwardPoint(op, point, size: size)
            size = forwardSize(op, current: size)
        }
        return point
    }

    // MARK: - 单步（左上原点，y 向下）

    /// op 之后的尺寸
    private static func forwardSize(_ op: ImageEditOperation.GeometryAction,
                                    current: CGSize) -> CGSize {
        switch op {
        case .rotate90cw, .rotate90ccw:
            return CGSize(width: current.height, height: current.width)
        case .flipH, .flipV:
            return current
        }
    }

    /// 正向点映射（old 尺寸坐标系 → op 后尺寸坐标系）。
    private static func forwardPoint(_ op: ImageEditOperation.GeometryAction,
                                     _ p: CGPoint, size: CGSize) -> CGPoint {
        switch op {
        case .rotate90cw:
            // (x, y) → (H − y, x)
            return CGPoint(x: size.height - p.y, y: p.x)
        case .rotate90ccw:
            // (x, y) → (y, W − x)
            return CGPoint(x: p.y, y: size.width - p.x)
        case .flipH:
            return CGPoint(x: size.width - p.x, y: p.y)
        case .flipV:
            return CGPoint(x: p.x, y: size.height - p.y)
        }
    }

    /// 逆向点映射（op 后尺寸坐标系 → op 前尺寸坐标系）。
    private static func inversePoint(_ op: ImageEditOperation.GeometryAction,
                                     _ p: CGPoint, size: CGSize) -> CGPoint {
        switch op {
        case .rotate90cw:
            // 正向 dx = H − y, dy = x → x = dy, y = H − dx（H = op 前高 = 显示宽）
            return CGPoint(x: p.y, y: size.width - p.x)
        case .rotate90ccw:
            // 正向 dx = y, dy = W − x → x = W − dy（W = op 后高）, y = dx
            return CGPoint(x: size.height - p.y, y: p.x)
        case .flipH:
            return CGPoint(x: size.width - p.x, y: p.y)
        case .flipV:
            return CGPoint(x: p.x, y: size.height - p.y)
        }
    }

    /// 逆推一步后的尺寸（op 之前的尺寸）。
    private static func backwardSize(_ op: ImageEditOperation.GeometryAction,
                                     current: CGSize) -> CGSize {
        switch op {
        case .rotate90cw, .rotate90ccw:
            return CGSize(width: current.height, height: current.width)
        case .flipH, .flipV:
            return current
        }
    }
}
