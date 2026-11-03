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

/// 管线操作（v0.8.41 批 1：adjust / filter / selection；几何后续批次接入）。
nonisolated struct ImageEditOperation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case adjust, filter, selection
    }

    var id: UUID
    var kind: Kind
    var label: String
    var isEnabled: Bool
    var adjust: ImageAdjustParams?
    var filter: String?
    var selection: ImageSelectionParams?

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
