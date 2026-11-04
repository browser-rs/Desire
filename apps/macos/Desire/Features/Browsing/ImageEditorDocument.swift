import Combine
import CoreGraphics
import Foundation

/// 图片编辑文档（v0.8.41 迭代 1）：调节/滤镜/选区的**非破坏**状态机。
/// 基础位图（几何/标注烙图后的结果）由视图持有；document 只管管线，
/// 渲染在后台 Task 做、带指纹缓存；undo/redo 针对管线快照。
@MainActor
final class ImageEditorDocument: ObservableObject {
    /// 管线快照（undo/redo 栈共用；redo 在 undo 时压入）。
    struct Snapshot {
        let pipeline: ImageEditPipeline
        let label: String
    }

    @Published private(set) var pipeline = ImageEditPipeline()
    /// 最近一次渲染结果（displayImage = render(base)）。
    @Published private(set) var renderedImage: CGImage?
    /// 渲染中（直方图/保存等用）。
    @Published private(set) var isRendering = false
    /// 自定义蒙版（魔棒 CGImage；非 nil 时渲染用它代替 selection op）。
    @Published private(set) var customMask: CGImage?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var renderTask: Task<Void, Never>?
    private var lastFingerprint: String?
    private var lastBase: CGImage?
    private static let maxHistory = 30
    /// 套索顶点（归一化；nil = 非套索）。渲染用。
    var lassoVertices: [CGPoint]? = nil
    var lassoFeather: Double = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - 修改（都记 undo，清 redo）

    /// 追加非调节操作（几何/滤镜/选区），记 undo。
    @discardableResult
    func append(_ operation: ImageEditOperation) -> Bool {
        push(Snapshot(pipeline: pipeline, label: operation.label))
        guard pipeline.append(operation) else {
            undoStack.removeLast()
            return false
        }
        objectWillChange.send()
        return true
    }

    /// 追加/替换当前 adjust 操作（调节面板 Apply）。
    @discardableResult
    func applyAdjust(_ params: ImageAdjustParams,
                     label: String = String(localized: "Adjustments")) -> Bool {
        let clamped = ImageAdjustParams.clamped(params)
        guard !clamped.isNeutral else { return false }
        push(Snapshot(pipeline: pipeline, label: label))
        // 已有同 label 的调节操作 = 再次调整时合并参数（保持操作数可控）。
        if let index = pipeline.operations.lastIndex(where: {
            $0.kind == .adjust && $0.label == label
        }), let existing = pipeline.operations[index].adjust {
            var merged = existing
            merged.brightness += clamped.brightness
            merged.contrast = ImageAdjustParams.clamped(
                ImageAdjustParams(contrast: existing.contrast * clamped.contrast)
            ).contrast
            merged.saturation = ImageAdjustParams.clamped(
                ImageAdjustParams(saturation: existing.saturation * clamped.saturation)
            ).saturation
            merged.sharpen = (existing.sharpen + clamped.sharpen).clamped(0, 2)
            merged.exposure = (existing.exposure + clamped.exposure).clamped(-2, 2)
            merged.temperature = (existing.temperature + clamped.temperature)
                .clamped(-100, 100)
            merged.tint = (existing.tint + clamped.tint).clamped(-100, 100)
            merged.highlights = (existing.highlights + clamped.highlights).clamped(-1, 1)
            merged.shadows = (existing.shadows + clamped.shadows).clamped(-1, 1)
            merged.vibrance = (existing.vibrance + clamped.vibrance).clamped(-1, 1)
            merged.clarity = max(existing.clarity, clamped.clarity)
            merged.denoise = max(existing.denoise, clamped.denoise)
            merged.vignette = max(existing.vignette, clamped.vignette)
            merged.vignetteFeather = clamped.vignetteFeather
            if clamped.hasAnyCurve {
                merged.curvePoints = clamped.curvePoints
                merged.curveRed = clamped.curveRed
                merged.curveGreen = clamped.curveGreen
                merged.curveBlue = clamped.curveBlue
            }
            merged.blackPoint = max(existing.blackPoint, clamped.blackPoint)
            merged.whitePoint = min(existing.whitePoint, clamped.whitePoint)
            if ImageAdjustParams.clamped(merged).isNeutral {
                pipeline.remove(pipeline.operations[index].id)
            } else {
                pipeline.updateAdjust(pipeline.operations[index].id, params: merged)
            }
        } else if !pipeline.append(.adjust(clamped, label: label)) {
            undoStack.removeLast()
            return false
        }
        objectWillChange.send()
        return true
    }

    func applyFilter(_ name: String) -> Bool {
        guard let preset = ImageFilterPreset(rawValue: name), preset != .none else {
            return false
        }
        push(Snapshot(pipeline: pipeline, label: preset.localizedTitle))
        // 同滤镜重复点击 = 更新既有项（不堆操作）。
        if pipeline.operations.contains(where: { $0.kind == .filter && $0.filter == name }) {
            pipeline.remove(pipeline.operations.first {
                $0.kind == .filter && $0.filter == name
            }!.id)
        }
        guard pipeline.append(.filter(name)) else {
            undoStack.removeLast()
            return false
        }
        objectWillChange.send()
        return true
    }

    func setSelection(_ params: ImageSelectionParams?) {
        push(Snapshot(pipeline: pipeline,
                      label: String(localized: "Selection")))
        pipeline.operations.removeAll { $0.kind == .selection }
        if let params, !ImageSelectionParams.clamped(params).isNeutral {
            _ = pipeline.append(.selection(params))
        }
        customMask = nil
        objectWillChange.send()
    }

    /// 套索多边形选区（v0.8.42）：写入 selection op 的 lassoVertices。
    func setLassoSelection(vertices: [CGPoint], feather: Double) {
        push(Snapshot(pipeline: pipeline,
                      label: String(localized: "Selection")))
        pipeline.operations.removeAll { $0.kind == .selection }
        customMask = nil
        if vertices.count >= 3 {
            let selection = ImageSelectionParams(
                x: 0, y: 0, width: 1, height: 1, ellipse: false, feather: 0)
            _ = pipeline.append(.selection(selection))
            lassoVertices = vertices
            lassoFeather = feather
        } else {
            lassoVertices = nil
            lassoFeather = 0
        }
        objectWillChange.send()
    }

    /// 魔棒蒙版选区（v0.8.42）：CGImage 蒙版 + 效果混回。
    func setCustomMask(_ mask: CGImage) {
        push(Snapshot(pipeline: pipeline,
                      label: String(localized: "Selection")))
        pipeline.operations.removeAll { $0.kind == .selection }
        customMask = mask
        lassoVertices = nil
        objectWillChange.send()
    }

    func clearCustomSelection() {
        customMask = nil
        lassoVertices = nil
        objectWillChange.send()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        push(Snapshot(pipeline: pipeline,
                      label: enabled ? String(localized: "Enable step")
                                     : String(localized: "Disable step")))
        pipeline.setEnabled(id, enabled)
        objectWillChange.send()
    }

    // MARK: - undo / redo

    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(pipeline: pipeline, label: previous.label))
        pipeline = previous.pipeline
        objectWillChange.send()
        return true
    }

    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(pipeline: pipeline, label: next.label))
        pipeline = next.pipeline
        objectWillChange.send()
        return true
    }

    private func push(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.maxHistory {
            undoStack.removeFirst(undoStack.count - Self.maxHistory)
        }
        redoStack.removeAll()
    }

    /// 恢复管线快照（重开文件时从 `.editstate.json` 读回）。
    func restorePipeline(_ pipeline: ImageEditPipeline) {
        self.pipeline = pipeline
        undoStack.removeAll()
        redoStack.removeAll()
        objectWillChange.send()
    }

    // MARK: - 渲染

    /// 请求渲染（去抖 120ms；相同指纹跳过）。base = 烙图后的基础位图。
    func requestRender(base: CGImage) {
        lastBase = base
        let fingerprint = pipeline.fingerprint() + "|\(base.width)x\(base.height)"
            + (customMask.map { "|custom|\($0.width)x\($0.height)" } ?? "")
            + (lassoVertices.map { "|lasso|\($0.count)" } ?? "")
        if fingerprint == lastFingerprint, renderedImage != nil { return }
        lastFingerprint = fingerprint
        renderTask?.cancel()
        isRendering = true
        let pipeline = pipeline
        let mask = customMask
        let lasso = lassoVertices
        let feather = lassoFeather
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let output = await Task.detached(priority: .userInitiated) {
                if let mask {
                    return ImagePipelineRenderer.renderWithCustomMask(
                        base: base, pipeline: pipeline, mask: mask)
                }
                if let lasso {
                    return ImagePipelineRenderer.renderWithLasso(
                        base: base, pipeline: pipeline, vertices: lasso,
                        feather: feather)
                }
                return ImagePipelineRenderer.render(base: base, pipeline: pipeline)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.renderedImage = output
            self.isRendering = false
        }
    }

    /// 同步渲染（保存/导出用；调用方自行放在后台）。
    nonisolated static func renderFinal(base: CGImage,
                                        pipeline: ImageEditPipeline) -> CGImage? {
        ImagePipelineRenderer.render(base: base, pipeline: pipeline)
    }
}
